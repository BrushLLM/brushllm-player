//! Media-server subsystem: the `servers.json` configuration store, five
//! protocol clients (WebDAV/SMB/FTP/Emby/Jellyfin) and the Tauri command
//! surface (`servers_*`).
//!
//! Dispatch mirrors the macOS `MediaServerBrowser`: browse routes by kind
//! (WebDAV path, FTP path, Emby ParentId, SMB share-relative path); playback
//! composes a URL mpv opens natively — http(s) with embedded Basic
//! credentials (mpv follows 302s itself, which is how 115/OpenList works),
//! ftp:// with credentials, an Emby direct-stream URL with `api_key`, or a
//! Windows UNC path.
pub mod dav;
pub mod emby;
pub mod ftp;
pub mod model;
pub mod smb;

use model::{
    kind_uses_emby_client, MediaItem, ServerSource, ServerStore, KIND_EMBY, KIND_FTP, KIND_JELLYFIN,
    KIND_SMB, KIND_WEBDAV,
};
use serde::Serialize;
use serde_json::{json, Value};

/// Unified command error: a stable `code` the frontend can switch on plus a
/// human-readable message (the per-protocol error enums map onto it).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerError {
    pub code: String,
    pub message: String,
}

impl ServerError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

impl std::fmt::Display for ServerError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}", self.message)
    }
}

impl From<dav::DavError> for ServerError {
    fn from(error: dav::DavError) -> Self {
        match error {
            dav::DavError::BadUrl => Self::new("badUrl", error.to_string()),
            dav::DavError::Http(code) => Self::new("http", format!("Server returned HTTP {code}")),
            dav::DavError::Parse => Self::new("parse", error.to_string()),
        }
    }
}

impl From<ftp::FtpError> for ServerError {
    fn from(error: ftp::FtpError) -> Self {
        match error {
            ftp::FtpError::BadUrl => Self::new("badUrl", error.to_string()),
            ftp::FtpError::Connection(_) => Self::new("connection", error.to_string()),
            ftp::FtpError::Login => Self::new("auth", error.to_string()),
            ftp::FtpError::Listing => Self::new("listing", error.to_string()),
            ftp::FtpError::Timeout => Self::new("timeout", error.to_string()),
            ftp::FtpError::ResponseTooLarge => Self::new("responseTooLarge", error.to_string()),
        }
    }
}

impl From<emby::EmbyError> for ServerError {
    fn from(error: emby::EmbyError) -> Self {
        match error {
            emby::EmbyError::BadUrl => Self::new("badUrl", error.to_string()),
            emby::EmbyError::Auth => Self::new("auth", error.to_string()),
            emby::EmbyError::Http(code) => Self::new("http", format!("Server returned HTTP {code}")),
        }
    }
}

impl From<smb::SmbError> for ServerError {
    fn from(error: smb::SmbError) -> Self {
        match error {
            smb::SmbError::BadUrl => Self::new("badUrl", error.to_string()),
            smb::SmbError::BadPath => Self::new("badPath", error.to_string()),
            smb::SmbError::BrowseRequiresWindows => Self::new("unsupported", error.to_string()),
            smb::SmbError::Io(_) => Self::new("io", error.to_string()),
        }
    }
}

/// mac `MediaServerBrowser.rootPath`: where browsing starts. An empty `path`
/// argument to `servers_browse` resolves to this.
pub fn root_path(source: &ServerSource) -> String {
    match source.kind.as_str() {
        KIND_WEBDAV => dav::base_path(source),
        KIND_FTP => ftp::root_path(source),
        _ => String::new(), // smb/emby/jellyfin start at the share/library root
    }
}

/// Emby item ids carry the media type (`video:{id}` / `audio:{id}`) so that
/// `servers_play(serverId, itemId)` alone can pick the stream endpoint.
/// Directory ids stay plain. Frontends treat ids as opaque.
fn tag_emby_items(items: Vec<MediaItem>) -> Vec<MediaItem> {
    items
        .into_iter()
        .map(|mut item| {
            if !item.is_directory && item.media_type.is_some() {
                let media_type = item.media_type.clone().unwrap_or_default();
                item.id = format!("{media_type}:{}", item.id);
            }
            item
        })
        .collect()
}

fn split_emby_id(item_id: &str) -> Option<(String, String)> {
    if let Some(id) = item_id.strip_prefix("video:") {
        Some(("video".to_string(), id.to_string()))
    } else if let Some(id) = item_id.strip_prefix("audio:") {
        Some(("audio".to_string(), id.to_string()))
    } else {
        None
    }
}

/// mac `MediaServerBrowser.list`: dispatch by kind. Blocking network I/O —
/// commands run this inside `spawn_blocking`.
pub fn browse(source: &ServerSource, path: &str) -> Result<Vec<MediaItem>, ServerError> {
    let path = if path.is_empty() {
        root_path(source)
    } else {
        path.to_string()
    };
    match source.kind.as_str() {
        KIND_WEBDAV => Ok(dav::list(source, &path)?),
        KIND_FTP => Ok(ftp::list(source, &path)?),
        KIND_EMBY | KIND_JELLYFIN => {
            // A tagged id is never a valid ParentId; strip defensively.
            let parent = split_emby_id(&path)
                .map(|(_, id)| id)
                .unwrap_or(path);
            Ok(tag_emby_items(emby::list(source, &parent)?))
        }
        KIND_SMB => Ok(smb::list(source, &path)?),
        other => Err(ServerError::new(
            "badUrl",
            format!("Unsupported server kind: {other}"),
        )),
    }
}

/// mac `MediaServerBrowser.playbackURL`: compose the URL/path mpv opens.
pub fn playback_url(source: &ServerSource, item_id: &str) -> Result<String, ServerError> {
    match source.kind.as_str() {
        KIND_WEBDAV => dav::playback_url(source, item_id)
            .ok_or_else(|| ServerError::new("badUrl", "Invalid WebDAV URL")),
        KIND_FTP => ftp::playback_url(source, item_id)
            .ok_or_else(|| ServerError::new("badUrl", "Invalid FTP URL")),
        KIND_SMB => Ok(smb::playback_path(source, item_id)?),
        KIND_EMBY | KIND_JELLYFIN => {
            let Some((media_type, id)) = split_emby_id(item_id) else {
                return Err(ServerError::new(
                    "notPlayable",
                    "This item cannot be played directly",
                ));
            };
            let item = MediaItem {
                id,
                name: String::new(),
                is_directory: false,
                size: 0,
                modified_at: None,
                media_type: Some(media_type),
            };
            Ok(emby::playback_url(source, &item)?)
        }
        other => Err(ServerError::new(
            "badUrl",
            format!("Unsupported server kind: {other}"),
        )),
    }
}

// ---- Tauri commands ----
// CRUD is synchronous and cheap (one small JSON file under a Mutex), like
// the library commands. Browse/play/test do blocking network I/O and run
// inside spawn_blocking off the async runtime.

#[tauri::command]
pub fn servers_list(store: tauri::State<'_, ServerStore>) -> Vec<ServerSource> {
    store.list()
}

#[tauri::command]
pub fn servers_add(
    store: tauri::State<'_, ServerStore>,
    kind: String,
    name: String,
    base_url: String,
    username: String,
    password: String,
) -> Result<ServerSource, ServerError> {
    store
        .add(kind, name, base_url, username, password)
        .map_err(|message| ServerError::new("store", message))
}

/// mac `MediaServerStore.update`: replaces the saved source by id; an empty
/// password keeps the stored one. The Emby session cache is invalidated on
/// every successful update — the mac rule invalidates on identity change or
/// a new password, and unconditionally invalidating is strictly at least as
/// conservative (the next browse re-authenticates once).
#[tauri::command]
pub fn servers_update(
    store: tauri::State<'_, ServerStore>,
    source: ServerSource,
    password: Option<String>,
) -> Result<bool, ServerError> {
    let mut source = source;
    if let Some(password) = password {
        source.password = password;
    }
    store
        .update(source.clone())
        .map_err(|message| ServerError::new("store", message))?;
    emby::SessionCache::shared().invalidate(&source.id);
    Ok(true)
}

#[tauri::command]
pub fn servers_remove(
    store: tauri::State<'_, ServerStore>,
    server_id: String,
) -> Result<bool, ServerError> {
    emby::SessionCache::shared().invalidate(&server_id);
    store
        .remove(&server_id)
        .map_err(|message| ServerError::new("store", message))?;
    Ok(true)
}

/// Lists one directory. `path: ""` (or omitted) starts at the server root.
#[tauri::command]
pub async fn servers_browse(
    store: tauri::State<'_, ServerStore>,
    server_id: String,
    path: String,
) -> Result<Vec<MediaItem>, ServerError> {
    let source = store
        .source(&server_id)
        .map_err(|message| ServerError::new("notFound", message))?;
    tauri::async_runtime::spawn_blocking(move || browse(&source, &path))
        .await
        .map_err(|error| ServerError::new("internal", format!("Browse task failed: {error}")))?
}

/// Plays one item: compose the URL (authenticating first for Emby), then
/// `loadfile replace` with the same reopen semantics as `load_file`.
#[tauri::command]
pub async fn servers_play(
    player: tauri::State<'_, crate::Player>,
    store: tauri::State<'_, ServerStore>,
    server_id: String,
    item_id: String,
) -> Result<crate::mpv::controller::CommandResult, ServerError> {
    let source = store
        .source(&server_id)
        .map_err(|message| ServerError::new("notFound", message))?;
    let player = player.0.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let url = playback_url(&source, &item_id)?;
        player
            .command(
                &[json!("loadfile"), json!(url), json!("replace")],
                true,
            )
            .map_err(|error| ServerError::new("player", error.message))
    })
    .await
    .map_err(|error| ServerError::new("internal", format!("Play task failed: {error}")))?
}

/// Appends one item to the playlist without interrupting playback
/// (folder-to-playlist: the frontend composes the list and appends each).
#[tauri::command]
pub async fn servers_enqueue(
    player: tauri::State<'_, crate::Player>,
    store: tauri::State<'_, ServerStore>,
    server_id: String,
    item_id: String,
) -> Result<crate::mpv::controller::CommandResult, ServerError> {
    let source = store
        .source(&server_id)
        .map_err(|message| ServerError::new("notFound", message))?;
    let player = player.0.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let url = playback_url(&source, &item_id)?;
        player
            .command(
                &[json!("loadfile"), json!(url), json!("append")],
                false,
            )
            .map_err(|error| ServerError::new("player", error.message))
    })
    .await
    .map_err(|error| ServerError::new("internal", format!("Enqueue task failed: {error}")))?
}

/// Connection test: list the root and report the first entry (mac behavior:
/// a successful root listing with at least one reachable entry).
#[tauri::command]
pub async fn servers_test(
    store: tauri::State<'_, ServerStore>,
    server_id: String,
) -> Result<Value, ServerError> {
    let source = store
        .source(&server_id)
        .map_err(|message| ServerError::new("notFound", message))?;
    let items = tauri::async_runtime::spawn_blocking(move || browse(&source, ""))
        .await
        .map_err(|error| ServerError::new("internal", format!("Test task failed: {error}")))??;
    Ok(json!({
        "ok": true,
        "rootItems": items.len(),
        "sample": items.first().map(|item| item.name.clone()),
    }))
}

/// Kind helper for the frontend-facing docs: which kinds use the Emby client.
#[allow(dead_code)]
pub fn uses_emby_client(kind: &str) -> bool {
    kind_uses_emby_client(kind)
}

#[cfg(test)]
#[path = "servers_tests.rs"]
mod tests;
