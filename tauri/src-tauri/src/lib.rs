mod library;
mod mpv;

use library::{Bookmark, HistoryEntry, LibraryStore};
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
            let mut player = MpvPlayer::new(Arc::new(move |snapshot| {
                let _ = handle.emit("mpv-state", snapshot);
            }));
            // IINA watch-later-directory: persistent resume data in the app
            // data dir (created on demand by the controller at spawn).
            let data_dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
            player.set_watch_later_dir(data_dir.join("watch_later"));
            app.manage(Player(Arc::new(player)));
            app.manage(LibraryStore::open(app.handle()));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            player_ready,
            player_snapshot,
            load_file,
            load_files,
            open_url,
            add_subtitle,
            open_subtitle_dialog,
            screenshot,
            playlist_command,
            toggle_pause,
            seek,
            seek_relative,
            stop_playback,
            set_property,
            send_command,
            open_file_dialog,
            history_list,
            history_record,
            history_update,
            history_remove,
            history_clear,
            history_play,
            bookmark_add,
            bookmark_list,
            bookmark_remove,
            bookmark_clear,
            playlist_save,
            playlist_restore,
        ])
        .build(tauri::generate_context!())
        .expect("error while building BrushLLM Player");
    app.run(|handle, event| {
        if matches!(
            event,
            tauri::RunEvent::ExitRequested { .. } | tauri::RunEvent::Exit
        ) {
            persist_on_exit(handle);
            if let Some(player) = handle.try_state::<Player>() {
                if let Err(error) = player.0.shutdown() {
                    log::warn!("{error}");
                }
            }
        }
    });
}

/// IINA savePlaybackPosition at app exit: write the mpv watch-later file, then
/// mirror the current playlist and position into library.json/playlist.json
/// before the player is shut down. Best effort; exit proceeds regardless.
fn persist_on_exit(handle: &tauri::AppHandle) {
    let Some(player) = handle.try_state::<Player>() else {
        return;
    };
    let store = handle.try_state::<LibraryStore>();
    let snapshot = player.0.snapshot();
    if snapshot.connected {
        let _ = player.0.command(&[json!("write-watch-later-config")], false);
    }
    let Some(store) = store else { return };
    // Playlist: filenames in order from the observed "playlist" property.
    if let Some(paths) = snapshot
        .properties
        .get("playlist")
        .and_then(|value| value.as_array())
    {
        let paths: Vec<String> = paths
            .iter()
            .filter_map(|entry| {
                entry
                    .get("filename")
                    .and_then(Value::as_str)
                    .filter(|name| !name.is_empty())
                    .map(str::to_owned)
            })
            .collect();
        if !paths.is_empty() {
            store.save_playlist(&paths);
        }
    }
    // Position/duration for the current file (media-title as the title).
    let filename = snapshot
        .properties
        .get("filename")
        .and_then(Value::as_str)
        .map(str::to_owned);
    if let Some(path) = filename {
        let position = snapshot
            .properties
            .get("time-pos")
            .and_then(Value::as_f64)
            .unwrap_or(0.0);
        let duration = snapshot
            .properties
            .get("duration")
            .and_then(Value::as_f64)
            .unwrap_or(0.0);
        store.update_position(&path, position, duration);
    }
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

/// Batch load: the first file replaces, the rest append (IINA addToPlaylist).
#[tauri::command]
async fn load_files(
    player: tauri::State<'_, Player>,
    paths: Vec<String>,
) -> Result<CommandResult, PlayerError> {
    let Some(first) = paths.first() else {
        return Err(player.0.error("load_files requires at least one path"));
    };
    let player = player.0.clone();
    let first_result = command(
        player.clone(),
        vec![json!("loadfile"), json!(first), json!("replace")],
        true,
    )
    .await?;
    for path in &paths[1..] {
        command(
            player.clone(),
            vec![json!("loadfile"), json!(path), json!("append")],
            false,
        )
        .await?;
    }
    Ok(CommandResult {
        generation: first_result.generation,
        data: json!(paths.len()),
    })
}

#[tauri::command]
async fn open_url(
    player: tauri::State<'_, Player>,
    url: String,
) -> Result<CommandResult, PlayerError> {
    command(
        player.0.clone(),
        vec![json!("loadfile"), json!(url), json!("replace")],
        true,
    )
    .await
}

/// External subtitle: flags "auto" lets mpv's default selection decide (IINA
/// loadExternalSubFile uses sub-add; "auto" avoids force-switching tracks).
#[tauri::command]
async fn add_subtitle(
    player: tauri::State<'_, Player>,
    path: String,
) -> Result<CommandResult, PlayerError> {
    command(
        player.0.clone(),
        vec![json!("sub-add"), json!(path), json!("auto")],
        false,
    )
    .await
}

/// Subtitle picker: a file dialog filtered to subtitle extensions that
/// feeds the chosen file straight to sub-add (IINA's LoadSubtitleView flow).
#[tauri::command]
async fn open_subtitle_dialog(
    player: tauri::State<'_, Player>,
    app: tauri::AppHandle,
) -> Result<Option<CommandResult>, PlayerError> {
    use tauri_plugin_dialog::DialogExt;
    let owner = player.0.clone();
    let file = tauri::async_runtime::spawn_blocking(move || {
        app.dialog()
            .file()
            .add_filter("Subtitles", &["srt", "ass", "ssa", "sub", "idx", "vtt", "sup"])
            .blocking_pick_file()
    })
    .await
    .map_err(|e| owner.error(format!("Subtitle dialog failed: {e}")))?;
    if let Some(file) = file {
        let path = file.into_path().map_err(|e| owner.error(e.to_string()))?;
        command(
            owner,
            vec![
                json!("sub-add"),
                json!(path.to_string_lossy()),
                json!("auto"),
            ],
            false,
        )
        .await
        .map(Some)
    } else {
        Ok(None)
    }
}

#[tauri::command]
async fn screenshot(player: tauri::State<'_, Player>) -> Result<CommandResult, PlayerError> {
    command(player.0.clone(), vec![json!("screenshot")], false).await
}

/// Parameterless playlist maintenance; indexed operations (playlist-move,
/// playlist-remove, playlist-play-index) go through send_command instead.
#[tauri::command]
async fn playlist_command(
    player: tauri::State<'_, Player>,
    op: String,
) -> Result<CommandResult, PlayerError> {
    match op.as_str() {
        "clear" | "shuffle" | "unshuffle" => {
            command(
                player.0.clone(),
                vec![json!(format!("playlist-{op}"))],
                false,
            )
            .await
        }
        _ => Err(player
            .0
            .error("playlist_command supports clear, shuffle, unshuffle")),
    }
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

/// IINA savePlaybackPosition pattern: persist the position for resume before
/// the playlist is kept and playback stops.
#[tauri::command]
async fn stop_playback(player: tauri::State<'_, Player>) -> Result<CommandResult, PlayerError> {
    let _ = command(
        player.0.clone(),
        vec![json!("write-watch-later-config")],
        false,
    )
    .await;
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
    // Multi-select: the first file replaces, the rest append (IINA
    // addToPlaylist batch behavior, same as load_files).
    let files = tauri::async_runtime::spawn_blocking(move || {
        app.dialog().file().blocking_pick_files()
    })
    .await
    .map_err(|e| owner.error(format!("File dialog failed: {e}")))?;
    let Some(files) = files else { return Ok(None) };
    let mut paths: Vec<String> = Vec::with_capacity(files.len());
    for file in files {
        let path = file.into_path().map_err(|e| owner.error(e.to_string()))?;
        paths.push(path.to_string_lossy().into_owned());
    }
    if paths.is_empty() {
        return Ok(None);
    }
    let Some(first) = paths.first() else { return Ok(None) };
    let first_result = command(
        owner.clone(),
        vec![json!("loadfile"), json!(first), json!("replace")],
        true,
    )
    .await?;
    for path in &paths[1..] {
        command(
            owner.clone(),
            vec![json!("loadfile"), json!(path), json!("append")],
            false,
        )
        .await?;
    }
    Ok(Some(CommandResult {
        generation: first_result.generation,
        data: json!(paths.len()),
    }))
}

// ---- Media library (history, bookmarks, saved playlist) ----
// All commands are synchronous and cheap (small JSON files under a Mutex);
// no async runtime hop is needed, matching player_snapshot's style.

#[tauri::command]
fn history_list(store: tauri::State<'_, LibraryStore>) -> Vec<HistoryEntry> {
    store.list_history()
}

#[tauri::command]
fn history_record(store: tauri::State<'_, LibraryStore>, path: String, title: String) {
    store.record_play(&path, &title);
}

#[tauri::command]
fn history_update(
    store: tauri::State<'_, LibraryStore>,
    path: String,
    position: f64,
    duration: f64,
) {
    store.update_position(&path, position, duration);
}

#[tauri::command]
fn history_remove(store: tauri::State<'_, LibraryStore>, path: String) {
    store.remove_history(&path);
}

#[tauri::command]
fn history_clear(store: tauri::State<'_, LibraryStore>) {
    store.clear_history();
}

/// Reopen from history: loadfile replace; mpv's resume-playback (watch-later)
/// seeks to the saved position automatically, so no explicit seek is sent.
#[tauri::command]
async fn history_play(
    player: tauri::State<'_, Player>,
    store: tauri::State<'_, LibraryStore>,
    path: String,
) -> Result<CommandResult, PlayerError> {
    let title = store
        .list_history()
        .iter()
        .find(|entry| entry.path == path)
        .map(|entry| entry.title.clone())
        .unwrap_or_default();
    store.record_play(&path, &title);
    command(
        player.0.clone(),
        vec![json!("loadfile"), json!(path), json!("replace")],
        true,
    )
    .await
}

#[tauri::command]
fn bookmark_add(
    store: tauri::State<'_, LibraryStore>,
    path: String,
    time: f64,
    title: String,
) -> Bookmark {
    store.add_bookmark(&path, time, &title)
}

#[tauri::command]
fn bookmark_list(store: tauri::State<'_, LibraryStore>, path: String) -> Vec<Bookmark> {
    store.list_bookmarks(&path)
}

#[tauri::command]
fn bookmark_remove(store: tauri::State<'_, LibraryStore>, id: u64) {
    store.remove_bookmark(id);
}

#[tauri::command]
fn bookmark_clear(store: tauri::State<'_, LibraryStore>, path: String) {
    store.clear_bookmarks(&path);
}

#[tauri::command]
fn playlist_save(store: tauri::State<'_, LibraryStore>, paths: Vec<String>) {
    store.save_playlist(&paths);
}

/// Rebuild the saved playlist with loadfile append; mpv stays idle (verified:
/// appending to an idle player does not start playback), so the frontend
/// decides when to start. An empty list is a successful no-op.
#[tauri::command]
async fn playlist_restore(
    player: tauri::State<'_, Player>,
    store: tauri::State<'_, LibraryStore>,
) -> Result<CommandResult, PlayerError> {
    let paths = store.load_playlist();
    let Some(first) = paths.first() else {
        return Ok(CommandResult {
            generation: player.0.snapshot().generation,
            data: json!(0),
        });
    };
    let first_result = command(
        player.0.clone(),
        vec![json!("loadfile"), json!(first), json!("append")],
        true,
    )
    .await?;
    for path in &paths[1..] {
        command(
            player.0.clone(),
            vec![json!("loadfile"), json!(path), json!("append")],
            false,
        )
        .await?;
    }
    Ok(CommandResult {
        generation: first_result.generation,
        data: json!(paths.len()),
    })
}
