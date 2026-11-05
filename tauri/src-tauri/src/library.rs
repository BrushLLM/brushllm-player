//! JSON media library: playback history, bookmarks and the saved playlist.
//!
//! Field semantics follow the macOS `PlaybackStore` (history upsert by path,
//! newest first; bookmarks per file sorted by time). Persistence is a single
//! `library.json` next to a `playlist.json` in the app data directory. The
//! `Library` core is AppHandle-free and unit-testable; `LibraryStore` is the
//! thin Tauri-managed wrapper that owns the directory and the Mutex.
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::Manager;

/// One history row per media path (mac `HistoryEntry`; `lastPlayedAt` is a
/// unix-seconds timestamp the frontend formats for display).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub path: String,
    pub title: String,
    pub duration: f64,
    pub position: f64,
    pub last_played_at: u64,
    pub play_count: u64,
}

/// A named playback position (mac `Bookmark`); `id` is a store-wide
/// auto-increment so removal survives duplicate path/time pairs.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Bookmark {
    pub id: u64,
    pub path: String,
    pub time: f64,
    pub title: String,
    pub created_at: u64,
}

/// The `library.json` payload.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Payload {
    pub history: Vec<HistoryEntry>,
    pub bookmarks: Vec<Bookmark>,
    #[serde(default)]
    pub next_bookmark_id: u64,
}

pub const LIBRARY_FILE: &str = "library.json";
pub const PLAYLIST_FILE: &str = "playlist.json";

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// mac `finite`: non-finite becomes 0, negatives are clamped to 0.
fn finite(value: f64) -> f64 {
    if value.is_finite() && value > 0.0 {
        value
    } else {
        0.0
    }
}

/// AppHandle-free core: in-memory state plus load/save against explicit
/// paths. All mutating methods take `&mut self`, so a plain `Mutex<Library>`
/// is the concurrency boundary; callers persist via `save` after mutating.
#[derive(Clone, Debug, Default)]
pub struct Library {
    history: Vec<HistoryEntry>,
    bookmarks: Vec<Bookmark>,
    next_bookmark_id: u64,
    /// Set when a loaded file was unreadable; writes are then refused so a
    /// corrupt library is never replaced by an empty one (mac rule).
    writes_disabled: bool,
}

impl Library {
    pub fn load(library_path: &Path) -> Self {
        let mut library = Self::default();
        let text = match std::fs::read_to_string(library_path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return library,
            Err(error) => {
                log::warn!("Cannot read library {}: {error}", library_path.display());
                library.writes_disabled = true;
                return library;
            }
        };
        match serde_json::from_str::<Payload>(&text) {
            Ok(payload) => {
                library.history = payload.history;
                library.bookmarks = payload.bookmarks;
                library.next_bookmark_id = payload.next_bookmark_id;
                // Repair a stale counter so restored stores never reuse IDs.
                let max_id = library
                    .bookmarks
                    .iter()
                    .map(|bookmark| bookmark.id)
                    .max()
                    .unwrap_or(0);
                library.next_bookmark_id = library.next_bookmark_id.max(max_id);
            }
            Err(error) => {
                log::warn!(
                    "Ignoring unreadable library {}: {error}",
                    library_path.display()
                );
                library.writes_disabled = true;
            }
        }
        library
    }

    /// Refuse writes to a damaged source and replace valid data atomically.
    pub fn save(&self, library_path: &Path) -> Result<(), String> {
        if self.writes_disabled {
            return Err(
                "The media library could not be read; its original data has been preserved".into(),
            );
        }
        atomic_json_write(
            library_path,
            &Payload {
                history: self.history.clone(),
                bookmarks: self.bookmarks.clone(),
                next_bookmark_id: self.next_bookmark_id,
            },
        )
    }

    /// Upsert by path (mac `recordPlay`): existing entries keep their position
    /// and duration and gain a play count; new entries start at 0/0.
    pub fn record_play(&mut self, path: &str, title: &str) {
        let now = unix_now();
        match self.history.iter_mut().find(|entry| entry.path == path) {
            Some(entry) => {
                if !title.is_empty() {
                    entry.title = title.to_owned();
                }
                entry.last_played_at = now;
                entry.play_count += 1;
            }
            None => self.history.push(HistoryEntry {
                path: path.to_owned(),
                title: title.to_owned(),
                duration: 0.0,
                position: 0.0,
                last_played_at: now,
                play_count: 1,
            }),
        }
    }

    /// Update position/duration; duration only ever grows (the largest known
    /// value wins, so a truncated early report cannot shrink it).
    pub fn update_position(&mut self, path: &str, position: f64, duration: f64) {
        let Some(entry) = self.history.iter_mut().find(|entry| entry.path == path) else {
            return;
        };
        entry.position = finite(position);
        let duration = finite(duration);
        if duration > entry.duration {
            entry.duration = duration;
        }
    }

    /// Newest first (mac ordering).
    pub fn list_history(&self) -> Vec<HistoryEntry> {
        let mut history = self.history.clone();
        history.sort_by(|a, b| b.last_played_at.cmp(&a.last_played_at));
        history
    }

    pub fn remove_history(&mut self, path: &str) {
        self.history.retain(|entry| entry.path != path);
    }

    pub fn clear_history(&mut self) {
        self.history.clear();
    }

    pub fn add_bookmark(&mut self, path: &str, time: f64, title: &str) -> Bookmark {
        self.next_bookmark_id += 1;
        let bookmark = Bookmark {
            id: self.next_bookmark_id,
            path: path.to_owned(),
            time: finite(time),
            title: title.to_owned(),
            created_at: unix_now(),
        };
        self.bookmarks.push(bookmark.clone());
        bookmark
    }

    /// Bookmarks for one file, earliest position first (mac ordering).
    pub fn list_bookmarks(&self, path: &str) -> Vec<Bookmark> {
        let mut bookmarks: Vec<Bookmark> = self
            .bookmarks
            .iter()
            .filter(|bookmark| bookmark.path == path)
            .cloned()
            .collect();
        bookmarks.sort_by(|a, b| {
            a.time
                .partial_cmp(&b.time)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        bookmarks
    }

    pub fn remove_bookmark(&mut self, id: u64) {
        self.bookmarks.retain(|bookmark| bookmark.id != id);
    }

    pub fn clear_bookmarks(&mut self, path: &str) {
        self.bookmarks.retain(|bookmark| bookmark.path != path);
    }
}

/// Write beside the destination, flush before rename, and never truncate the
/// previous file. Rust's rename replaces existing files on Unix and Windows.
fn atomic_json_write(path: &Path, value: &impl Serialize) -> Result<(), String> {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);
    let bytes = serde_json::to_vec_pretty(value).map_err(|error| error.to_string())?;
    let dir = path
        .parent()
        .filter(|dir| !dir.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)
        .map_err(|error| format!("Cannot create media library directory: {error}"))?;
    let name = path
        .file_name()
        .ok_or("Invalid media library filename")?
        .to_string_lossy();
    let (temp, mut file) = loop {
        let temp = dir.join(format!(
            ".{name}.{}-{}.tmp",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
        {
            Ok(file) => break (temp, file),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("Cannot save media library: {error}")),
        }
    };
    let result = (|| {
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temp, path)
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("Cannot save media library: {error}"));
    }
    Ok(())
}

/// Saved playlist: a plain JSON array of paths in `playlist.json`.
pub fn save_playlist_file(playlist_path: &Path, paths: &[String]) -> Result<(), String> {
    match std::fs::read_to_string(playlist_path) {
        Ok(text) => {
            serde_json::from_str::<Vec<String>>(&text).map_err(|_| {
                "The saved playlist could not be read; its original data has been preserved"
                    .to_string()
            })?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
        Err(error) => return Err(format!("Cannot read saved playlist: {error}")),
    }
    atomic_json_write(playlist_path, &paths)
}

pub fn load_playlist_file(playlist_path: &Path) -> Vec<String> {
    let Ok(text) = std::fs::read_to_string(playlist_path) else {
        return Vec::new();
    };
    match serde_json::from_str::<Vec<String>>(&text) {
        Ok(paths) => paths,
        Err(error) => {
            log::warn!(
                "Ignoring unreadable playlist {}: {error}",
                playlist_path.display()
            );
            Vec::new()
        }
    }
}

/// Tauri-managed state. Commit the in-memory mutation only after persistence
/// succeeds, so callers can report failures without showing unsaved changes.
#[derive(Clone)]
pub struct LibraryStore {
    library_path: PathBuf,
    playlist_path: PathBuf,
    library: Arc<Mutex<Library>>,
}

impl LibraryStore {
    /// Resolves `<app_data_dir>/library.json` and `playlist.json`, creating
    /// the directory when missing. Falls back to the temp dir only when the
    /// resolver itself fails; never panics during Tauri setup.
    ///
    /// Returns `Self`, NOT `Arc<Self>`: `app.manage()` registers the exact
    /// type it is given, and the commands resolve `State<'_, LibraryStore>` —
    /// managing an `Arc<LibraryStore>` makes every history/bookmark command
    /// fail with "state not managed" at runtime.
    pub fn open(app: &tauri::AppHandle) -> Self {
        let dir = app.path().app_data_dir().unwrap_or_else(|error| {
            log::warn!("Cannot resolve app data dir, using temp dir: {error}");
            std::env::temp_dir().join("brushllm-player-library")
        });
        let library_path = dir.join(LIBRARY_FILE);
        Self {
            library: Arc::new(Mutex::new(Library::load(&library_path))),
            library_path,
            playlist_path: dir.join(PLAYLIST_FILE),
        }
    }

    fn mutate<T>(&self, change: impl FnOnce(&mut Library) -> T) -> Result<T, String> {
        let mut library = self.library.lock();
        let mut candidate = library.clone();
        let result = change(&mut candidate);
        candidate.save(&self.library_path)?;
        *library = candidate;
        Ok(result)
    }

    pub fn record_play(&self, path: &str, title: &str) -> Result<(), String> {
        self.mutate(|library| library.record_play(path, title))
    }

    pub fn update_position(&self, path: &str, position: f64, duration: f64) -> Result<(), String> {
        self.mutate(|library| library.update_position(path, position, duration))
    }

    pub fn list_history(&self) -> Vec<HistoryEntry> {
        self.library.lock().list_history()
    }

    pub fn remove_history(&self, path: &str) -> Result<(), String> {
        self.mutate(|library| library.remove_history(path))
    }

    pub fn clear_history(&self) -> Result<(), String> {
        self.mutate(|library| library.clear_history())
    }

    pub fn add_bookmark(&self, path: &str, time: f64, title: &str) -> Result<Bookmark, String> {
        self.mutate(|library| library.add_bookmark(path, time, title))
    }

    pub fn list_bookmarks(&self, path: &str) -> Vec<Bookmark> {
        self.library.lock().list_bookmarks(path)
    }

    pub fn remove_bookmark(&self, id: u64) -> Result<(), String> {
        self.mutate(|library| library.remove_bookmark(id))
    }

    pub fn clear_bookmarks(&self, path: &str) -> Result<(), String> {
        self.mutate(|library| library.clear_bookmarks(path))
    }

    pub fn save_playlist(&self, paths: &[String]) -> Result<(), String> {
        // Also serializes concurrent playlist saves.
        let _guard = self.library.lock();
        save_playlist_file(&self.playlist_path, paths)
    }

    pub fn load_playlist(&self) -> Vec<String> {
        load_playlist_file(&self.playlist_path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "brushllm-library-{name}-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn record_play_upserts_by_path_and_orders_newest_first() {
        let mut library = Library::default();
        library.record_play("/m/a.mkv", "A");
        let first = library.list_history()[0].clone();
        assert_eq!(first.play_count, 1);
        assert_eq!(first.duration, 0.0);
        assert_eq!(first.position, 0.0);
        assert!(first.last_played_at > 0);
        // Distinct manual timestamps make the ordering deterministic.
        library.history[0].last_played_at = 100;
        library.record_play("/m/b.mkv", "B");
        library.history[1].last_played_at = 50;
        library.record_play("/m/a.mkv", "A2");
        let history = library.list_history();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].path, "/m/a.mkv");
        assert_eq!(history[0].play_count, 2);
        assert_eq!(history[0].title, "A2");
        assert_eq!(history[1].path, "/m/b.mkv");
        assert_eq!(history[1].play_count, 1);
        // An empty title refresh keeps the previous title.
        library.record_play("/m/b.mkv", "");
        assert_eq!(library.list_history()[1].title, "B");
    }

    #[test]
    fn update_position_sets_position_and_keeps_largest_duration() {
        let mut library = Library::default();
        library.record_play("/m/a.mkv", "A");
        library.update_position("/m/a.mkv", 12.5, 120.0);
        library.update_position("/m/a.mkv", 130.0, 90.0);
        let entry = &library.list_history()[0];
        assert_eq!(entry.position, 130.0);
        assert_eq!(entry.duration, 120.0);
        // Unknown paths are ignored, non-finite values become 0.
        library.update_position("/m/unknown.mkv", 5.0, 5.0);
        assert_eq!(library.list_history().len(), 1);
        library.update_position("/m/a.mkv", f64::NAN, f64::NAN);
        assert_eq!(library.list_history()[0].position, 0.0);
        assert_eq!(library.list_history()[0].duration, 120.0);
    }

    #[test]
    fn history_remove_and_clear() {
        let mut library = Library::default();
        library.record_play("/m/a.mkv", "A");
        library.record_play("/m/b.mkv", "B");
        library.remove_history("/m/a.mkv");
        assert_eq!(library.list_history().len(), 1);
        assert_eq!(library.list_history()[0].path, "/m/b.mkv");
        library.clear_history();
        assert!(library.list_history().is_empty());
    }

    #[test]
    fn bookmarks_auto_increment_and_sort_by_time() {
        let mut library = Library::default();
        let late = library.add_bookmark("/m/a.mkv", 90.0, "Late");
        let early = library.add_bookmark("/m/a.mkv", 10.0, "Early");
        let other = library.add_bookmark("/m/b.mkv", 5.0, "Other");
        assert!(late.id < early.id && early.id < other.id);
        let bookmarks = library.list_bookmarks("/m/a.mkv");
        assert_eq!(bookmarks.len(), 2);
        assert_eq!(bookmarks[0].title, "Early");
        assert_eq!(bookmarks[1].title, "Late");
        assert_eq!(library.list_bookmarks("/m/b.mkv").len(), 1);
        assert!(library.list_bookmarks("/m/c.mkv").is_empty());
        library.remove_bookmark(early.id);
        assert_eq!(library.list_bookmarks("/m/a.mkv").len(), 1);
        library.clear_bookmarks("/m/a.mkv");
        assert!(library.list_bookmarks("/m/a.mkv").is_empty());
        assert_eq!(library.list_bookmarks("/m/b.mkv").len(), 1);
        // IDs keep growing after removals; they are never reused.
        let next = library.add_bookmark("/m/b.mkv", 7.0, "Next");
        assert!(next.id > other.id);
    }

    #[test]
    fn library_save_load_roundtrip_preserves_state() {
        let dir = temp_dir("roundtrip");
        let path = dir.join(LIBRARY_FILE);
        let mut library = Library::default();
        library.record_play("/m/a.mkv", "A");
        library.update_position("/m/a.mkv", 42.0, 100.0);
        library.record_play("/m/b.mkv", "B");
        library.add_bookmark("/m/a.mkv", 33.0, "Mark");
        library.save(&path).unwrap();
        let reloaded = Library::load(&path);
        assert_eq!(reloaded.list_history(), library.list_history());
        assert_eq!(
            reloaded.list_bookmarks("/m/a.mkv"),
            library.list_bookmarks("/m/a.mkv")
        );
        // nextBookmarkId survives so restored stores never reuse IDs.
        let mut reloaded = reloaded;
        let next = reloaded.add_bookmark("/m/a.mkv", 44.0, "Second");
        assert_eq!(next.id, 2);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn payload_is_camel_case_json() {
        let mut library = Library::default();
        library.record_play("/m/a.mkv", "A");
        library.add_bookmark("/m/a.mkv", 33.0, "Mark");
        let payload = Payload {
            history: library.list_history(),
            bookmarks: library.list_bookmarks("/m/a.mkv"),
            next_bookmark_id: 1,
        };
        let json = serde_json::to_value(&payload).unwrap();
        assert!(json["history"][0].get("lastPlayedAt").is_some());
        assert!(json["history"][0].get("playCount").is_some());
        assert!(json["bookmarks"][0].get("createdAt").is_some());
        assert!(json.get("nextBookmarkId").is_some());
        assert!(json["history"][0].get("last_played_at").is_none());
    }

    #[test]
    fn corrupt_library_is_never_replaced_by_an_empty_store() {
        let dir = temp_dir("corrupt");
        let path = dir.join(LIBRARY_FILE);
        std::fs::write(&path, "not json").unwrap();
        let mut library = Library::load(&path);
        library.record_play("/m/a.mkv", "A");
        assert!(library.save(&path).is_err());
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "not json",
            "writes must be refused while the source is unreadable"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn failed_save_does_not_commit_memory_or_consume_bookmark_ids() {
        let dir = temp_dir("failed-transaction");
        let blocker = dir.join("blocked");
        std::fs::write(&blocker, b"keep").unwrap();
        let store = LibraryStore {
            library_path: blocker.join(LIBRARY_FILE),
            playlist_path: dir.join(PLAYLIST_FILE),
            library: Arc::new(Mutex::new(Library::default())),
        };
        assert!(store.record_play("/a/same.mkv", "A").is_err());
        assert!(store.add_bookmark("/a/same.mkv", 12.0, "A").is_err());
        assert!(store.list_history().is_empty());
        assert!(store.list_bookmarks("/a/same.mkv").is_empty());
        assert_eq!(std::fs::read(&blocker).unwrap(), b"keep");
        std::fs::remove_file(&blocker).unwrap();
        let bookmark = store.add_bookmark("/a/same.mkv", 12.0, "A").unwrap();
        assert_eq!(bookmark.id, 1);
        store.record_play("/a/same.mkv", "A").unwrap();
        store.record_play("/b/same.mkv", "B").unwrap();
        store.add_bookmark("/b/same.mkv", 24.0, "B").unwrap();
        let reloaded = Library::load(&store.library_path);
        assert_eq!(reloaded.list_history().len(), 2);
        assert_eq!(reloaded.list_bookmarks("/a/same.mkv")[0].time, 12.0);
        assert_eq!(reloaded.list_bookmarks("/b/same.mkv")[0].time, 24.0);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn atomic_replace_preserves_destination_on_failure_and_cleans_staging_files() {
        let dir = temp_dir("atomic-failure");
        let destination = dir.join("existing-directory");
        std::fs::create_dir(&destination).unwrap();
        std::fs::write(destination.join("keep"), b"original").unwrap();
        assert!(atomic_json_write(&destination, &vec!["new"]).is_err());
        assert_eq!(
            std::fs::read(destination.join("keep")).unwrap(),
            b"original"
        );
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        let path = dir.join(PLAYLIST_FILE);
        std::fs::write(&path, b"damaged original").unwrap();
        assert!(save_playlist_file(&path, &[]).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"damaged original");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn playlist_roundtrip_and_missing_files() {
        let dir = temp_dir("playlist");
        let path = dir.join(PLAYLIST_FILE);
        assert!(load_playlist_file(&path).is_empty());
        save_playlist_file(&path, &["/m/a.mkv".into(), "/m/b.mkv".into()]).unwrap();
        assert_eq!(load_playlist_file(&path), vec!["/m/a.mkv", "/m/b.mkv"]);
        save_playlist_file(&path, &[]).unwrap();
        assert!(load_playlist_file(&path).is_empty());
        std::fs::write(&path, "broken").unwrap();
        assert!(load_playlist_file(&path).is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
