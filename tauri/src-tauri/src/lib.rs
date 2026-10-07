mod mpv;

use mpv::controller::{CommandResult, MpvPlayer, PlayerError, StateSnapshot};
use serde_json::{json, Value};
use std::sync::Arc;
use tauri::{Emitter, Manager};

/// Shared owner, not a permanently-bound IPC connection. A dead mpv is rebuilt
/// only on frontend readiness or the next open; ordinary controls report errors.
struct Player(Arc<MpvPlayer>);

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            // Preserve the independent video window on every platform. Frontend
            // installs its listener before player_ready starts IPC/observers.
            let handle = app.handle().clone();
            app.manage(Player(Arc::new(MpvPlayer::new(Arc::new(
                move |snapshot| {
                    let _ = handle.emit("mpv-state", snapshot);
                },
            )))));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            player_ready,
            player_snapshot,
            load_file,
            toggle_pause,
            seek,
            seek_relative,
            stop_playback,
            set_property,
            send_command,
            open_file_dialog,
        ])
        .build(tauri::generate_context!())
        .expect("error while building BrushLLM Player");
    app.run(|handle, event| {
        if matches!(
            event,
            tauri::RunEvent::ExitRequested { .. } | tauri::RunEvent::Exit
        ) {
            if let Some(player) = handle.try_state::<Player>() {
                if let Err(error) = player.0.shutdown() {
                    log::warn!("{error}");
                }
            }
        }
    });
}

/// IPC waits run off the event/UI thread. No async-runtime dependency added.
async fn command(
    player: Arc<MpvPlayer>,
    args: Vec<Value>,
    reopen: bool,
) -> Result<CommandResult, PlayerError> {
    let fallback = player.clone();
    tauri::async_runtime::spawn_blocking(move || player.command(&args, reopen))
        .await
        .map_err(|e| fallback.error(format!("Player task failed: {e}")))?
}

#[tauri::command]
async fn player_ready(player: tauri::State<'_, Player>) -> Result<StateSnapshot, PlayerError> {
    let player = player.0.clone();
    let fallback = player.clone();
    tauri::async_runtime::spawn_blocking(move || player.ready())
        .await
        .map_err(|e| fallback.error(format!("Player startup failed: {e}")))?
}

#[tauri::command]
fn player_snapshot(player: tauri::State<'_, Player>) -> StateSnapshot {
    player.0.snapshot()
}

#[tauri::command]
async fn load_file(
    player: tauri::State<'_, Player>,
    path: String,
) -> Result<CommandResult, PlayerError> {
    command(
        player.0.clone(),
        vec![json!("loadfile"), json!(path), json!("replace")],
        true,
    )
    .await
}

#[tauri::command]
async fn toggle_pause(player: tauri::State<'_, Player>) -> Result<CommandResult, PlayerError> {
    command(
        player.0.clone(),
        vec![json!("cycle"), json!("pause")],
        false,
    )
    .await
}

#[tauri::command]
async fn seek(
    player: tauri::State<'_, Player>,
    position: f64,
) -> Result<CommandResult, PlayerError> {
    command(
        player.0.clone(),
        vec![json!("seek"), json!(position), json!("absolute+exact")],
        false,
    )
    .await
}

#[tauri::command]
async fn seek_relative(
    player: tauri::State<'_, Player>,
    seconds: f64,
) -> Result<CommandResult, PlayerError> {
    command(
        player.0.clone(),
        vec![json!("seek"), json!(seconds), json!("relative+exact")],
        false,
    )
    .await
}

#[tauri::command]
async fn stop_playback(player: tauri::State<'_, Player>) -> Result<CommandResult, PlayerError> {
    command(
        player.0.clone(),
        vec![json!("stop"), json!("keep-playlist")],
        false,
    )
    .await
}

#[tauri::command]
async fn set_property(
    player: tauri::State<'_, Player>,
    name: String,
    value: String,
) -> Result<CommandResult, PlayerError> {
    command(
        player.0.clone(),
        vec![json!("set_property"), json!(name), json!(value)],
        false,
    )
    .await
}

#[tauri::command]
async fn send_command(
    player: tauri::State<'_, Player>,
    args: Vec<Value>,
) -> Result<CommandResult, PlayerError> {
    // Legacy string arrays are still accepted, with typed numbers also allowed.
    let reopen = args.first().and_then(Value::as_str) == Some("loadfile");
    command(player.0.clone(), args, reopen).await
}

#[tauri::command]
async fn open_file_dialog(
    player: tauri::State<'_, Player>,
    app: tauri::AppHandle,
) -> Result<Option<CommandResult>, PlayerError> {
    use tauri_plugin_dialog::DialogExt;
    let owner = player.0.clone();
    let file =
        tauri::async_runtime::spawn_blocking(move || app.dialog().file().blocking_pick_file())
            .await
            .map_err(|e| owner.error(format!("File dialog failed: {e}")))?;
    if let Some(file) = file {
        let path = file.into_path().map_err(|e| owner.error(e.to_string()))?;
        command(
            owner,
            vec![
                json!("loadfile"),
                json!(path.to_string_lossy()),
                json!("replace"),
            ],
            true,
        )
        .await
        .map(Some)
    } else {
        Ok(None)
    }
}
