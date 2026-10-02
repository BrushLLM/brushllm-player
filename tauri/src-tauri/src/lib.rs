mod mpv;

use mpv::controller::MpvController;
use tauri::Manager;
use std::sync::Arc;

/// Shared player instance (one per app).
struct Player(Arc<MpvController>);

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            // mpv opens its own window on every platform for now:
            // - macOS: NSView pointers are process-specific, so cross-process
            //   --wid embedding is not possible.
            // - Windows: HWND embedding is possible in principle, but WebView2
            //   fills the client area and would fight mpv's child window for
            //   z-order. Revisit with a transparent-overlay design.
            let wid = 0;

            let controller = Arc::new(MpvController::new(app.handle().clone(), wid));
            app.manage(Player(controller));
            log::info!("BrushLLM Player started (mpv subprocess, wid={})", wid);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            load_file,
            toggle_pause,
            seek,
            seek_relative,
            stop_playback,
            set_property,
            send_command,
            open_file_dialog,
        ])
        .run(tauri::generate_context!())
        .expect("error while running BrushLLM Player");
}

// MARK: - IPC commands (called from the React frontend)

#[tauri::command]
fn load_file(player: tauri::State<Player>, path: String) -> Result<(), String> {
    player.0.load_file(&path)
}

#[tauri::command]
fn toggle_pause(player: tauri::State<Player>) {
    player.0.toggle_pause();
}

#[tauri::command]
fn seek(player: tauri::State<Player>, position: f64) {
    player.0.seek(position);
}

#[tauri::command]
fn seek_relative(player: tauri::State<Player>, seconds: f64) {
    player.0.seek_relative(seconds);
}

#[tauri::command]
fn stop_playback(player: tauri::State<Player>) {
    player.0.stop();
}

#[tauri::command]
fn set_property(player: tauri::State<Player>, name: String, value: String) -> Result<(), String> {
    player.0.set_property(&name, &value)
}

#[tauri::command]
fn send_command(player: tauri::State<Player>, args: Vec<String>) -> Result<(), String> {
    player.0.send_command(&args)
}

#[tauri::command]
async fn open_file_dialog(player: tauri::State<'_, Player>, app: tauri::AppHandle) -> Result<(), String> {
    use tauri_plugin_dialog::DialogExt;
    let file = app.dialog().file().blocking_pick_file();
    if let Some(file_path) = file {
        let path = file_path.into_path().map_err(|e| e.to_string())?;
        player.0.load_file(&path.to_string_lossy())?;
    }
    Ok(())
}
