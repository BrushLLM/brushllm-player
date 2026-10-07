//! mpv remains an independent native video window. JSON IPC is reader-first;
//! requests are registered before writing and never wait while owning a writer.
use super::transport::{self, Cancel, Transport};
use parking_lot::Mutex;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::io::Read;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender, TrySendError};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
const STARTUP_TIMEOUT: Duration = Duration::from_secs(5);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_millis(1500);
const QUIT_GRACE: Duration = Duration::from_millis(150);
const MAX_LINE: usize = 1024 * 1024;
const QUEUE_CAPACITY: usize = 64;
const OBSERVED: [(&str, u64); 11] = [
    ("pause", 1),
    ("time-pos", 2),
    ("duration", 3),
    ("idle-active", 4),
    ("media-title", 5),
    ("filename", 6),
    ("volume", 7),
    ("mute", 8),
    ("speed", 9),
    ("playlist-count", 10),
    ("playlist-pos", 11),
];

type Reply = Result<Value, String>;
pub type StateSink = Arc<dyn Fn(StateSnapshot) + Send + Sync>;

#[derive(Clone, Debug, Serialize)]
pub struct EndFile {
    pub reason: String,
    pub file_error: Option<String>,
}

/// Full snapshots make delayed frontend startup/refresh recoverable. Revisions
/// also order an invoke snapshot against events already in the webview queue.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StateSnapshot {
    pub generation: u64,
    pub media_epoch: u64,
    pub revision: u64,
    pub connected: bool,
    pub ready: bool,
    pub properties: BTreeMap<String, Value>,
    pub end_file: Option<EndFile>,
    pub error: Option<String>,
}

impl StateSnapshot {
    fn empty(generation: u64) -> Self {
        Self {
            generation,
            media_epoch: 0,
            revision: 0,
            connected: false,
            ready: false,
            properties: BTreeMap::new(),
            end_file: None,
            error: None,
        }
    }
}

struct SharedInner {
    snapshot: StateSnapshot,
    pending: HashMap<u64, Sender<Reply>>,
}
struct Shared {
    inner: Mutex<SharedInner>,
    sink: StateSink,
}
impl Shared {
    fn new(generation: u64, sink: StateSink) -> Self {
        Self {
            inner: Mutex::new(SharedInner {
                snapshot: StateSnapshot::empty(generation),
                pending: HashMap::new(),
            }),
            sink,
        }
    }
    fn snapshot(&self) -> StateSnapshot {
        self.inner.lock().snapshot.clone()
    }
    fn publish(&self, snapshot: StateSnapshot) {
        (self.sink)(snapshot);
    }
    fn update(&self, change: impl FnOnce(&mut StateSnapshot)) {
        let snapshot = {
            let mut inner = self.inner.lock();
            if !inner.snapshot.connected {
                return;
            }
            change(&mut inner.snapshot);
            inner.snapshot.revision += 1;
            inner.snapshot.clone()
        };
        self.publish(snapshot);
    }
    fn connected(&self, closing: &AtomicBool) -> bool {
        let snapshot = {
            let mut inner = self.inner.lock();
            if closing.load(Ordering::Acquire) {
                return false;
            }
            inner.snapshot.connected = true;
            inner.snapshot.revision += 1;
            inner.snapshot.clone()
        };
        self.publish(snapshot);
        true
    }
    fn invalidate(&self, message: Option<String>) {
        let (snapshot, pending) = {
            let mut inner = self.inner.lock();
            let was_connected = inner.snapshot.connected;
            inner.snapshot.connected = false;
            inner.snapshot.ready = false;
            inner.snapshot.properties.clear();
            if let Some(message) = message {
                inner.snapshot.error = Some(message);
            }
            if !was_connected && inner.pending.is_empty() {
                return;
            }
            inner.snapshot.revision += 1;
            (inner.snapshot.clone(), std::mem::take(&mut inner.pending))
        };
        for (_, reply) in pending {
            let _ = reply.send(Err("mpv IPC disconnected".into()));
        }
        self.publish(snapshot);
    }
    fn dispatch(&self, message: Value) {
        if let Some(id) = message.get("request_id").and_then(Value::as_u64) {
            let reply = self.inner.lock().pending.remove(&id);
            if let Some(reply) = reply {
                let result = match message.get("error").and_then(Value::as_str) {
                    Some("success") => Ok(message.get("data").cloned().unwrap_or(Value::Null)),
                    Some(error) => Err(format!("mpv command failed: {error}")),
                    None => Err("mpv reply missing error status".into()),
                };
                let _ = reply.send(result);
            }
            return; // Late replies never mutate state or satisfy another request.
        }
        match message.get("event").and_then(Value::as_str) {
            Some("property-change") => {
                let Some(name) = message.get("name").and_then(Value::as_str) else {
                    return;
                };
                if !OBSERVED.iter().any(|(property, _)| *property == name) {
                    return;
                }
                let value = message.get("data").cloned().unwrap_or(Value::Null);
                self.update(|state| {
                    state.properties.insert(name.to_owned(), value);
                });
            }
            Some("start-file") => self.update(|state| {
                state.media_epoch += 1;
                state.error = None;
                state.end_file = None;
                for property in ["time-pos", "duration", "media-title", "filename"] {
                    state.properties.insert(property.into(), Value::Null);
                }
            }),
            Some("file-loaded") => self.update(|state| {
                state.error = None;
                state.end_file = None;
            }),
            Some("end-file") => {
                let reason = message
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .to_owned();
                let file_error = message
                    .get("file_error")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                self.update(|state| {
                    state.error = (reason == "error").then(|| {
                        file_error
                            .clone()
                            .unwrap_or_else(|| "Media loading failed".into())
                    });
                    state.end_file = Some(EndFile { reason, file_error });
                });
            }
            Some("shutdown") => self.invalidate(None),
            _ => (),
        }
    }
}

struct WriteJob {
    bytes: Vec<u8>,
    deadline: Instant,
    /// None is the best-effort quit job; no response is required at exit.
    request: Option<u64>,
}
#[derive(Default)]
struct Workers {
    sender: Option<SyncSender<WriteJob>>,
    cancel: Option<Arc<dyn Cancel>>,
    threads: Vec<JoinHandle<()>>,
}

pub struct MpvController {
    child: Mutex<Option<Child>>,
    workers: Mutex<Workers>,
    shared: Arc<Shared>,
    request_id: AtomicU64,
    closing: AtomicBool,
    stop_workers: Arc<AtomicBool>,
    endpoint: String,
    #[cfg(not(target_os = "windows"))]
    endpoint_dir: PathBuf,
}

#[derive(Clone)]
struct LaunchConfig {
    binary: PathBuf,
    args: Vec<String>,
    /// Tests use a synthetic media directory and isolated HOME/config/cache.
    isolation: Option<PathBuf>,
}
impl Default for LaunchConfig {
    fn default() -> Self {
        Self {
            binary: MpvController::find_mpv(),
            isolation: None,
            args: vec![
                "--no-terminal",
                "--no-config",
                "--load-scripts=no",
                "--no-osc",
                "--keepaspect=yes",
                "--hwdec=auto-safe",
                "--cache=yes",
                "--idle=yes",
                "--vo=gpu-next",
                "--save-position-on-quit=no",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        }
    }
}

impl MpvController {
    /// Spawn and register ownership BEFORE waiting for the IPC endpoint. This
    /// lets app exit kill a process even while another command is starting it.
    fn spawn(generation: u64, sink: StateSink, config: &LaunchConfig) -> Result<Self, String> {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let name = format!("brushllm-{}-{generation}-{nonce:x}", std::process::id());
        #[cfg(not(target_os = "windows"))]
        let endpoint_dir = {
            use std::os::unix::fs::DirBuilderExt;
            // Short private path stays inside Unix sockaddr limits on macOS.
            let dir = PathBuf::from("/tmp").join(&name);
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&dir)
                .map_err(|e| e.to_string())?;
            dir
        };
        #[cfg(not(target_os = "windows"))]
        let endpoint = endpoint_dir.join("ipc.sock").to_string_lossy().into_owned();
        #[cfg(target_os = "windows")]
        let endpoint = format!("\\\\.\\pipe\\{name}");
        let mut controller = Self {
            child: Mutex::new(None),
            workers: Mutex::new(Workers::default()),
            shared: Arc::new(Shared::new(generation, sink)),
            request_id: AtomicU64::new(1),
            closing: AtomicBool::new(false),
            stop_workers: Arc::new(AtomicBool::new(false)),
            endpoint,
            #[cfg(not(target_os = "windows"))]
            endpoint_dir,
        };
        let mut command = Command::new(&config.binary);
        command
            .args(&config.args)
            .arg(format!("--input-ipc-server={}", controller.endpoint));
        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Some(dir) = &config.isolation {
            command
                .current_dir(dir)
                .env("HOME", dir)
                .env("XDG_CONFIG_HOME", dir)
                .env("XDG_CACHE_HOME", dir)
                .env("XDG_STATE_HOME", dir);
        }
        *controller.child.get_mut() = Some(
            command
                .spawn()
                .map_err(|e| format!("Failed to launch mpv: {e}"))?,
        );
        Ok(controller)
    }

    fn initialize(&self, timeout: Duration) -> Result<(), String> {
        let deadline = Instant::now() + timeout;
        loop {
            if self.closing.load(Ordering::Acquire) {
                return Err("Player is shutting down".into());
            }
            if let Some(child) = self.child.lock().as_mut() {
                if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                    return Err(format!("mpv exited during startup: {status}"));
                }
            }
            if let Ok(transport) = transport::connect(&self.endpoint) {
                self.attach(transport)?;
                break;
            }
            if Instant::now() >= deadline {
                return Err("Timed out connecting to mpv IPC".into());
            }
            std::thread::sleep(
                transport::IO_POLL.min(deadline.saturating_duration_since(Instant::now())),
            );
        }
        // The reader and reply dispatcher are already running. All IDs are JSON
        // numbers; ordinary property string values remain legal and unchanged.
        for (name, id) in OBSERVED {
            self.request_until(
                &[json!("observe_property"), json!(id), json!(name)],
                deadline,
            )?;
        }
        // Initial observer events can follow their acknowledgement. A get reply
        // barrier drains them before ready; frontend also already listens, and
        // every subsequent event includes the full cached state.
        self.request_until(&[json!("get_property"), json!("idle-active")], deadline)?;
        self.shared.update(|state| state.ready = true);
        if !self.is_ready() {
            return Err("mpv disconnected during startup".into());
        }
        Ok(())
    }

    fn attach(&self, transport: Transport) -> Result<(), String> {
        let mut workers = self.workers.lock();
        if self.closing.load(Ordering::Acquire) {
            transport.cancel.cancel();
            return Err("Player is shutting down".into());
        }
        if !self.shared.connected(&self.closing) {
            transport.cancel.cancel();
            return Err("Player is shutting down".into());
        }
        let Transport {
            mut reader,
            mut writer,
            cancel,
        } = transport;
        let (sender, jobs): (SyncSender<WriteJob>, Receiver<WriteJob>) =
            mpsc::sync_channel(QUEUE_CAPACITY);
        workers.sender = Some(sender);
        workers.cancel = Some(cancel.clone());
        // Start reader FIRST; one connection owns one pending map and generation.
        let shared = self.shared.clone();
        let stopped = self.stop_workers.clone();
        let reader_cancel = cancel.clone();
        workers.threads.push(std::thread::spawn(move || {
            let mut buffer = [0u8; 8192];
            let mut line = Vec::new();
            let failure = loop {
                if stopped.load(Ordering::Acquire) || !shared.snapshot().connected {
                    break None;
                }
                match reader.read(&mut buffer) {
                    Ok(0) => break Some("mpv IPC closed".to_owned()),
                    Ok(count) => {
                        for byte in &buffer[..count] {
                            if *byte == b'\n' {
                                if let Ok(message) = serde_json::from_slice::<Value>(&line) {
                                    shared.dispatch(message);
                                }
                                line.clear();
                            } else {
                                line.push(*byte);
                            }
                        }
                        if line.len() > MAX_LINE {
                            break Some("mpv IPC message exceeded size limit".into());
                        }
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            std::io::ErrorKind::Interrupted
                                | std::io::ErrorKind::TimedOut
                                | std::io::ErrorKind::WouldBlock
                        ) =>
                    {
                        ()
                    }
                    Err(_) => break Some("mpv IPC read failed".to_owned()),
                }
            };
            shared.invalidate(failure);
            reader_cancel.cancel();
        }));
        let shared = self.shared.clone();
        let stopped = self.stop_workers.clone();
        workers.threads.push(std::thread::spawn(move || {
            while !stopped.load(Ordering::Acquire) {
                let job = match jobs.recv_timeout(transport::IO_POLL) {
                    Ok(job) => job,
                    Err(mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                };
                if let Some(id) = job.request {
                    if !shared.inner.lock().pending.contains_key(&id) {
                        continue;
                    }
                    if Instant::now() >= job.deadline {
                        if let Some(reply) = shared.inner.lock().pending.remove(&id) {
                            let _ = reply.send(Err("mpv request timed out before write".into()));
                        }
                        continue;
                    }
                }
                if writer.write_until(&job.bytes, job.deadline).is_err() {
                    // A partial JSON line must never be reused as a new command.
                    shared.invalidate(Some("mpv IPC write failed".into()));
                    cancel.cancel();
                    break;
                }
            }
        }));
        Ok(())
    }

    fn request_until(&self, args: &[Value], deadline: Instant) -> Reply {
        if self.closing.load(Ordering::Acquire) {
            return Err("Player is shutting down".into());
        }
        if Instant::now() >= deadline {
            return Err("mpv request timed out".into());
        }
        let id = self.request_id.fetch_add(1, Ordering::Relaxed);
        let (reply, response) = mpsc::channel();
        let mut bytes = serde_json::to_vec(&json!({ "command": args, "request_id": id }))
            .map_err(|e| e.to_string())?;
        bytes.push(b'\n');
        {
            let mut inner = self.shared.inner.lock();
            if !inner.snapshot.connected {
                return Err("mpv IPC disconnected; open a file to restart".into());
            }
            inner.pending.insert(id, reply);
        }
        let sender = self.workers.lock().sender.clone();
        let queued = match sender {
            Some(sender) => sender.try_send(WriteJob {
                bytes,
                deadline,
                request: Some(id),
            }),
            None => Err(TrySendError::Disconnected(WriteJob {
                bytes,
                deadline,
                request: Some(id),
            })),
        };
        if let Err(error) = queued {
            self.shared.inner.lock().pending.remove(&id);
            return Err(match error {
                TrySendError::Full(_) => "mpv request queue is full",
                _ => "mpv writer disconnected",
            }
            .into());
        }
        // No writer, process or state lock is held during the bounded wait.
        match response.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(result) => result,
            Err(_) => {
                self.shared.inner.lock().pending.remove(&id);
                Err("mpv request timed out".into())
            }
        }
    }
    pub fn send_command(&self, args: &[Value]) -> Reply {
        self.request_until(args, Instant::now() + REQUEST_TIMEOUT)
    }
    pub fn snapshot(&self) -> StateSnapshot {
        self.shared.snapshot()
    }
    fn is_ready(&self) -> bool {
        let state = self.snapshot();
        state.connected && state.ready && !self.closing.load(Ordering::Acquire)
    }

    /// Absolute deadline includes queuing quit, killing, reaping and worker
    /// cleanup. Killing/cancelling NEVER waits for the writer or for a reply.
    pub fn shutdown(&self) -> Result<(), String> {
        self.shutdown_for(SHUTDOWN_TIMEOUT)
    }
    fn shutdown_for(&self, timeout: Duration) -> Result<(), String> {
        if self.closing.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let deadline = Instant::now() + timeout;
        self.shared.invalidate(None);
        let graceful_deadline = (Instant::now() + QUIT_GRACE).min(deadline);
        if let Some(workers) = self.workers.try_lock_until(graceful_deadline) {
            if let Some(sender) = &workers.sender {
                let _ = sender.try_send(WriteJob {
                    bytes: b"{\"command\":[\"quit\"]}\n".to_vec(),
                    deadline: graceful_deadline,
                    request: None,
                });
            }
        }
        while Instant::now() < graceful_deadline {
            if self.reap_until(deadline) {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        self.stop_workers.store(true, Ordering::Release);
        // No writer lock/ack is needed for the force-termination path.
        if let Some(mut child) = self.child.try_lock_until(deadline) {
            if let Some(child) = child.as_mut() {
                let _ = child.kill();
            }
        }
        if let Some(workers) = self.workers.try_lock_until(deadline) {
            if let Some(cancel) = &workers.cancel {
                cancel.cancel();
            }
        }
        let mut reaped = false;
        let mut drained = false;
        while Instant::now() < deadline {
            reaped = self.reap_until(deadline);
            if let Some(mut workers) = self.workers.try_lock_until(deadline) {
                workers.sender.take();
                let mut index = 0;
                while index < workers.threads.len() {
                    if workers.threads[index].is_finished() {
                        let _ = workers.threads.swap_remove(index).join();
                    } else {
                        index += 1;
                    }
                }
                drained = workers.threads.is_empty();
            }
            if reaped && drained {
                break;
            }
            std::thread::sleep(
                Duration::from_millis(5).min(deadline.saturating_duration_since(Instant::now())),
            );
        }
        #[cfg(not(target_os = "windows"))]
        {
            // Only the endpoint in this controller's private directory. No stale
            // or external paths are recursively deleted.
            let _ = std::fs::remove_file(&self.endpoint);
            let _ = std::fs::remove_dir(&self.endpoint_dir);
        }
        if reaped && drained {
            Ok(())
        } else {
            Err("mpv cleanup exceeded its deadline".into())
        }
    }
    fn reap_until(&self, deadline: Instant) -> bool {
        let Some(mut child) = self.child.try_lock_until(deadline) else {
            return false;
        };
        let Some(process) = child.as_mut() else {
            return true;
        };
        match process.try_wait() {
            Ok(Some(_)) => {
                child.take();
                true
            }
            Ok(None) => false,
            Err(error) => {
                log::warn!("mpv reap failed: {error}");
                false
            }
        }
    }
    fn find_mpv() -> PathBuf {
        let exe_name = if cfg!(target_os = "windows") {
            "mpv.exe"
        } else {
            "mpv"
        };
        if let Ok(exe) = std::env::current_exe() {
            for ancestor in exe.ancestors().skip(1) {
                let candidate = ancestor.join("bin").join(exe_name);
                if candidate.exists() {
                    return candidate;
                }
            }
            #[cfg(target_os = "macos")]
            if let Some(resources) = exe.parent().map(|p| p.join("../Resources/bin/mpv")) {
                if resources.exists() {
                    return resources;
                }
            }
        }
        PathBuf::from(exe_name)
    }
}
impl Drop for MpvController {
    fn drop(&mut self) {
        if let Err(error) = self.shutdown() {
            log::warn!("{error}");
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct PlayerError {
    pub generation: u64,
    pub message: String,
}
#[derive(Debug, Serialize)]
pub struct CommandResult {
    pub generation: u64,
    pub data: Value,
}

/// A short slot lock protects ownership, not I/O. Startup has a separate gate;
/// exit never needs that gate and can see the child before IPC initialization.
pub struct MpvPlayer {
    current: Mutex<Option<Arc<MpvController>>>,
    startup: Mutex<()>,
    generation: AtomicU64,
    exiting: AtomicBool,
    sink: StateSink,
    config: LaunchConfig,
}
impl MpvPlayer {
    pub fn new(sink: StateSink) -> Self {
        Self {
            current: Mutex::new(None),
            startup: Mutex::new(()),
            generation: AtomicU64::new(0),
            exiting: AtomicBool::new(false),
            sink,
            config: LaunchConfig::default(),
        }
    }
    pub fn snapshot(&self) -> StateSnapshot {
        self.current
            .lock()
            .as_ref()
            .map(|player| player.snapshot())
            .unwrap_or_else(|| StateSnapshot::empty(self.generation.load(Ordering::Acquire)))
    }
    pub fn error(&self, message: impl Into<String>) -> PlayerError {
        PlayerError {
            generation: self.snapshot().generation,
            message: message.into(),
        }
    }
    fn ensure(&self) -> Result<Arc<MpvController>, PlayerError> {
        if self.exiting.load(Ordering::Acquire) {
            return Err(self.error("Player is shutting down"));
        }
        if let Some(current) = self
            .current
            .lock()
            .as_ref()
            .filter(|p| p.is_ready())
            .cloned()
        {
            return Ok(current);
        }
        let _startup = self
            .startup
            .try_lock_for(STARTUP_TIMEOUT + SHUTDOWN_TIMEOUT)
            .ok_or_else(|| self.error("Timed out waiting for player startup"))?;
        if self.exiting.load(Ordering::Acquire) {
            return Err(self.error("Player is shutting down"));
        }
        if let Some(current) = self
            .current
            .lock()
            .as_ref()
            .filter(|p| p.is_ready())
            .cloned()
        {
            return Ok(current);
        }
        // Keep the old child visible to app exit until cleanup completes; an
        // exit concurrent with reconnect must not see an empty ownership slot.
        let previous = self.current.lock().clone();
        if let Some(previous) = previous {
            previous.shutdown().map_err(|message| PlayerError {
                generation: previous.snapshot().generation,
                message,
            })?;
        }
        let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        let controller = {
            let mut current = self.current.lock();
            if self.exiting.load(Ordering::Acquire) {
                return Err(PlayerError {
                    generation,
                    message: "Player is shutting down".into(),
                });
            }
            let controller = Arc::new(
                MpvController::spawn(generation, self.sink.clone(), &self.config).map_err(
                    |message| PlayerError {
                        generation,
                        message,
                    },
                )?,
            );
            *current = Some(controller.clone());
            controller
        };
        if let Err(message) = controller.initialize(STARTUP_TIMEOUT) {
            controller.shared.invalidate(Some(message.clone()));
            let _ = controller.shutdown();
            return Err(PlayerError {
                generation,
                message,
            });
        }
        Ok(controller)
    }
    pub fn ready(&self) -> Result<StateSnapshot, PlayerError> {
        Ok(self.ensure()?.snapshot())
    }
    pub fn command(&self, args: &[Value], reopen: bool) -> Result<CommandResult, PlayerError> {
        let current = if reopen {
            self.ensure()?
        } else {
            let current = self.current.lock().clone().filter(|p| p.is_ready());
            current.ok_or_else(|| self.error("mpv is disconnected; open a file to restart"))?
        };
        let generation = current.snapshot().generation;
        current
            .send_command(args)
            .map(|data| CommandResult { generation, data })
            .map_err(|message| PlayerError {
                generation,
                message,
            })
    }
    pub fn shutdown(&self) -> Result<(), String> {
        self.exiting.store(true, Ordering::Release);
        let current = self.current.lock().clone();
        if let Some(current) = current {
            current.shutdown()
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
#[path = "controller_tests.rs"]
mod tests;
