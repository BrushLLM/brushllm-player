//! mpv controller via subprocess + JSON IPC.
//!
//! Architecture: mpv runs as a child process rendering into its own native
//! window. All control flows through mpv's JSON IPC protocol — a Unix
//! domain socket on macOS/Linux, a named pipe on Windows. Both are duplex
//! byte streams speaking the same JSON-lines protocol.
//!
//! This avoids all native library linking — the mpv binary handles
//! rendering, decoding, and platform integration natively.

use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

// The IPC transport differs by platform but carries the same protocol.
// Windows named pipes are opened as regular files.
#[cfg(target_os = "windows")]
type IpcStream = std::fs::File;
#[cfg(not(target_os = "windows"))]
type IpcStream = std::os::unix::net::UnixStream;

#[cfg(target_os = "windows")]
fn connect_ipc(path: &str) -> std::io::Result<IpcStream> {
    std::fs::OpenOptions::new().read(true).write(true).open(path)
}

#[cfg(not(target_os = "windows"))]
fn connect_ipc(path: &str) -> std::io::Result<IpcStream> {
    std::os::unix::net::UnixStream::connect(path)
}

pub struct MpvController {
    child: std::sync::Mutex<Option<Child>>,
    writer: std::sync::Mutex<IpcStream>,
    request_id: AtomicU64,
    /// Unix socket path — removed on quit. Windows named pipes are
    /// cleaned up by the server (mpv) itself when it exits.
    #[cfg(not(target_os = "windows"))]
    socket_path: String,
}

impl MpvController {
    /// Launches mpv with IPC. `wid` embeds mpv into a native window
    /// handle when non-zero (HWND on Windows is system-wide; NSView
    /// pointers on macOS are process-specific, so embedding across
    /// processes is not possible there).
    pub fn new(app: tauri::AppHandle, wid: i64) -> Self {
        #[cfg(target_os = "windows")]
        let socket_path = format!("\\\\.\\pipe\\brushllm-player-{}", std::process::id());
        #[cfg(not(target_os = "windows"))]
        let socket_path = {
            let p = format!("/tmp/brushllm-player-{}.sock", std::process::id());
            // Remove a stale socket from a crashed run.
            let _ = std::fs::remove_file(&p);
            p
        };

        let mpv_path = Self::find_mpv();
        let mut cmd = Command::new(mpv_path);
        cmd.args([
            "--no-terminal",
            "--no-config",
            "--no-osc",
            // NOTE: --input-ipc-server MUST use the = syntax; the
            // space-separated form silently fails to create the socket.
            &format!("--input-ipc-server={}", socket_path),
            "--keepaspect=yes",
            "--hwdec=auto-safe",
            "--cache=yes",
            "--idle=yes",
            "--vo=gpu-next",
        ]);
        if wid != 0 {
            cmd.arg(format!("--wid={}", wid));
        }
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        let mut child = cmd.spawn().expect("failed to launch mpv — is it installed?");
        log::info!("mpv launched (pid={}), wid={}", child.id(), wid);

        // Wait for the IPC endpoint to appear (mpv creates it after startup).
        let mut connected = None;
        for i in 0..50 {
            if let Ok(Some(status)) = child.try_wait() {
                panic!("mpv died during startup: {:?}", status);
            }
            if let Ok(stream) = connect_ipc(&socket_path) {
                connected = Some(stream);
                break;
            }
            if i % 10 == 0 {
                log::debug!("waiting for mpv IPC endpoint (attempt {})...", i);
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        let stream = connected.expect("mpv IPC endpoint never appeared");
        log::info!("mpv IPC connected at {}", socket_path);

        // Split into reader/writer.
        let writer = stream.try_clone().expect("clone IPC stream");
        let reader = BufReader::new(stream);

        let controller = Self {
            child: std::sync::Mutex::new(Some(child)),
            writer: std::sync::Mutex::new(writer),
            request_id: AtomicU64::new(0),
            #[cfg(not(target_os = "windows"))]
            socket_path,
        };

        // Observe the properties the UI is driven by.
        let observed = [
            ("pause", 1), ("time-pos", 2), ("duration", 3),
            ("idle-active", 4), ("media-title", 5), ("filename", 6),
            ("volume", 7), ("mute", 8), ("speed", 9),
            ("playlist-count", 10), ("playlist-pos", 11),
        ];
        for (name, id) in observed {
            let _ = controller.send_command(&[
                "observe_property".to_string(),
                id.to_string(),
                name.to_string(),
            ]);
        }

        // Event reader thread: forwards mpv events to the webview.
        controller.start_event_loop(reader, app);

        controller
    }

    fn start_event_loop(&self, mut reader: BufReader<IpcStream>, app: tauri::AppHandle) {
        use tauri::Emitter;
        std::thread::spawn(move || {
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => break, // EOF or error — mpv exited
                    Ok(_) => {
                        let trimmed = line.trim();
                        if trimmed.is_empty() { continue; }
                        if let Ok(msg) = serde_json::from_str::<Value>(trimmed) {
                            if let Some(event) = msg.get("event").and_then(|e| e.as_str()) {
                                if event == "property-change" {
                                    let name = msg.get("name").and_then(|n| n.as_str()).unwrap_or("");
                                    let data = msg.get("data").cloned().unwrap_or(Value::Null);
                                    let _ = app.emit("mpv-property", serde_json::json!({
                                        "name": name,
                                        "value": data,
                                    }));
                                } else if event == "file-loaded" {
                                    let _ = app.emit("mpv-file-loaded", ());
                                } else if event == "end-file" {
                                    let reason = msg.get("reason").and_then(|r| r.as_i64()).unwrap_or(0);
                                    let _ = app.emit("mpv-end-file", reason);
                                }
                            }
                        }
                    }
                }
            }
            let _ = app.emit("mpv-shutdown", ());
        });
    }

    /// Sends a JSON IPC command.
    pub fn send_command(&self, args: &[String]) -> Result<(), String> {
        let id = self.request_id.fetch_add(1, Ordering::SeqCst);
        let payload = serde_json::json!({
            "command": args,
            "request_id": id,
        });
        let mut writer = self.writer.lock().map_err(|e| e.to_string())?;
        if let Err(e) = writeln!(&mut *writer, "{}", payload) {
            return Err(format!("IPC write failed: {}", e));
        }
        Ok(())
    }

    pub fn load_file(&self, path: &str) -> Result<(), String> {
        self.send_command(&["loadfile".into(), path.into(), "replace".into()])
    }

    pub fn set_property(&self, name: &str, value: &str) -> Result<(), String> {
        self.send_command(&["set_property".into(), name.into(), value.into()])
    }

    pub fn toggle_pause(&self) {
        let _ = self.send_command(&["cycle".into(), "pause".into()]);
    }

    pub fn seek(&self, seconds: f64) {
        let _ = self.send_command(&[
            "seek".into(), format!("{:.3}", seconds), "absolute+exact".into(),
        ]);
    }

    pub fn seek_relative(&self, seconds: f64) {
        let _ = self.send_command(&[
            "seek".into(), format!("{:.3}", seconds), "relative+exact".into(),
        ]);
    }

    pub fn stop(&self) {
        let _ = self.send_command(&["stop".into(), "keep-playlist".into()]);
    }

    pub fn quit(&self) {
        let _ = self.send_command(&["quit".into()]);
        #[cfg(not(target_os = "windows"))]
        let _ = std::fs::remove_file(&self.socket_path);
    }

    /// Locates the mpv binary: bundled next to the app, or in PATH.
    fn find_mpv() -> String {
        let exe_name = if cfg!(target_os = "windows") { "mpv.exe" } else { "mpv" };
        // Dev: src-tauri/bin/mpv (found by walking up from the executable).
        if let Ok(exe) = std::env::current_exe() {
            for ancestor in exe.ancestors().skip(1) {
                let candidate = ancestor.join("bin").join(exe_name);
                if candidate.exists() {
                    return candidate.to_string_lossy().to_string();
                }
            }
        }
        // Production: bundled as resources (macOS Contents/Resources/bin;
        // Windows install-dir bin/ is covered by the walk above).
        #[cfg(target_os = "macos")]
        if let Ok(exe) = std::env::current_exe() {
            if let Some(r) = exe.parent().map(|p| p.join("../Resources/bin/mpv")) {
                if r.exists() {
                    return r.to_string_lossy().to_string();
                }
            }
        }
        // System PATH.
        "mpv".to_string()
    }
}

impl Drop for MpvController {
    fn drop(&mut self) {
        self.quit();
        if let Ok(mut guard) = self.child.lock() {
            if let Some(mut child) = guard.take() {
                let _ = child.wait();
            }
        }
    }
}
