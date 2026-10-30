//! Media-server data model and the `servers.json` configuration store.
//!
//! Field semantics follow the macOS `MediaServer.swift`: `MediaItem` is one
//! browse row (id = protocol-specific path/identifier), `ServerSource` is one
//! saved server. The macOS app splits metadata (UserDefaults) and passwords
//! (Keychain); Windows has no directly usable Keychain equivalent in this
//! stack, so the simplified port keeps the password in the same JSON file
//! under the per-user app data directory (natural user isolation). Swapping
//! in the Windows Credential Manager later only means changing `SecretFile`.
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// mac `MediaServerKind`: webdav/smb/ftp/emby/jellyfin (jellyfin shares the
/// Emby client; the kind only affects display and playability rules).
pub const KIND_WEBDAV: &str = "webdav";
pub const KIND_SMB: &str = "smb";
pub const KIND_FTP: &str = "ftp";
pub const KIND_EMBY: &str = "emby";
pub const KIND_JELLYFIN: &str = "jellyfin";

pub fn kind_uses_emby_client(kind: &str) -> bool {
    kind == KIND_EMBY || kind == KIND_JELLYFIN
}

/// mac `MediaItem`. `modified_at` is ISO8601 text or a unix-seconds string
/// (the frontend parses both); `media_type` is Some("audio"/"video") for Emby
/// items and None for filesystem-like listings.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MediaItem {
    pub id: String,
    pub name: String,
    pub is_directory: bool,
    pub size: i64,
    pub modified_at: Option<String>,
    pub media_type: Option<String>,
}

impl MediaItem {
    /// mac `MediaItem.isPlayable`: directories never play; Emby/Jellyfin need
    /// a media type; filesystem-like kinds use the extension whitelist. The
    /// frontend applies the same rule before calling `servers_play` (the mac
    /// backend does not enforce it either); kept for parity and tests.
    #[allow(dead_code)]
    pub fn is_playable(&self, kind: &str) -> bool {
        if self.is_directory {
            return false;
        }
        if kind_uses_emby_client(kind) {
            return matches!(
                self.media_type.as_deref(),
                Some("audio") | Some("video")
            );
        }
        PLAYABLE_EXTENSIONS
            .contains(&extension_of(&self.name).as_str())
    }
}

/// mac `MediaTypes.playableExtensions` (audio + video formats mpv opens).
#[allow(dead_code)]
const PLAYABLE_EXTENSIONS: &[&str] = &[
    // video
    "mkv", "mp4", "m4v", "mov", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "ts", "m2ts", "mts",
    "vob", "3gp", "ogm", "rm", "rmvb", "asf", "divx", "f4v", "mxf", "wtv",
    // audio
    "mp3", "flac", "ape", "wma", "aac", "m4a", "m4b", "ogg", "oga", "opus", "wav", "wave", "aiff",
    "aif", "alac", "wv", "tta", "tak", "dsf", "dff", "aax", "ac3", "dts", "mka",
    // images (mpv displays them; kept for parity with picture browsing)
    "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "tif", "jxl", "avif", "heic",
    // playlists
    "m3u", "m3u8", "pls",
];

#[allow(dead_code)]
fn extension_of(name: &str) -> String {
    let name = name.rsplit('/').next().unwrap_or(name);
    match name.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() && !extension.is_empty() => {
            extension.to_ascii_lowercase()
        }
        _ => String::new(),
    }
}

/// mac `MediaServerSource` (id is a UUID string; kind is one of the
/// `KIND_*` constants). `password` lives in the same file — see the module
/// docs for the simplified Windows credential decision.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ServerSource {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub base_url: String,
    pub username: String,
    #[serde(default)]
    pub password: String,
}

/// The `servers.json` payload.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServersPayload {
    pub servers: Vec<ServerSource>,
}

pub const SERVERS_FILE: &str = "servers.json";

/// mac `MediaServerStore` semantics: add/update/remove/list with immediate
/// persistence. The macOS revision/auxiliary-secret machinery exists to keep
/// Keychain secrets coherent with UserDefaults metadata; with one JSON file
/// under one lock the same guarantees come for free, so the port keeps the
/// simple CRUD surface. A corrupt file is kept (never overwritten) and
/// reported through `load_error`, mirroring the mac `loadFailed` rule.
pub struct ServerStore {
    path: PathBuf,
    state: Mutex<ServerState>,
}

pub struct ServerState {
    servers: Vec<ServerSource>,
    load_error: bool,
}

impl ServerStore {
    /// Resolves `<app_data_dir>/servers.json`, creating the directory when
    /// missing (same fallback policy as `LibraryStore::open`).
    pub fn open(app: &tauri::AppHandle) -> std::sync::Arc<Self> {
        use tauri::Manager;
        let dir = app.path().app_data_dir().unwrap_or_else(|error| {
            log::warn!("Cannot resolve app data dir, using temp dir: {error}");
            std::env::temp_dir().join("brushllm-player-servers")
        });
        Arc::new(Self::open_at(&dir.join(SERVERS_FILE)))
    }

    /// Testable constructor against an explicit file path.
    pub fn open_at(path: &Path) -> Self {
        Self {
            path: path.to_path_buf(),
            state: Mutex::new(Self::load(path)),
        }
    }

    fn load(path: &Path) -> ServerState {
        let Ok(text) = std::fs::read_to_string(path) else {
            return ServerState {
                servers: Vec::new(),
                load_error: false,
            }; // missing file = fresh store
        };
        match serde_json::from_str::<ServersPayload>(&text) {
            Ok(payload) => ServerState {
                servers: payload.servers,
                load_error: false,
            },
            Err(error) => {
                log::warn!("Ignoring unreadable servers file {}: {error}", path.display());
                ServerState {
                    servers: Vec::new(),
                    load_error: true,
                }
            }
        }
    }

    /// Persists under the lock; a load failure refuses writes so a corrupt
    /// file is never silently replaced (mac `loadFailed` rule). The file is
    /// created owner-only where the platform supports it (Unix 0600; on
    /// Windows the per-user app data directory provides the isolation).
    fn persist(state: &ServerState, path: &Path) -> Result<(), String> {
        if state.load_error {
            return Err("The saved server configuration could not be decoded".into());
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("Cannot create config directory: {error}"))?;
        }
        let text = serde_json::to_string_pretty(&ServersPayload {
            servers: state.servers.clone(),
        })
        .map_err(|error| format!("Cannot encode servers: {error}"))?;
        std::fs::write(path, text).map_err(|error| format!("Cannot save servers: {error}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Err(error) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
                log::warn!("Could not restrict servers.json permissions: {error}");
            }
        }
        Ok(())
    }

    pub fn list(&self) -> Vec<ServerSource> {
        self.state.lock().servers.clone()
    }

    /// mac `add`: a new UUID source is appended and persisted.
    pub fn add(
        &self,
        kind: String,
        name: String,
        base_url: String,
        username: String,
        password: String,
    ) -> Result<ServerSource, String> {
        let mut state = self.state.lock();
        if state.load_error {
            return Err("The saved server configuration could not be decoded".into());
        }
        let source = ServerSource {
            id: new_uuid(),
            kind,
            name,
            base_url,
            username,
            password,
        };
        state.servers.push(source.clone());
        Self::persist(&state, &self.path)?;
        Ok(source)
    }

    /// mac `update`: replaces the saved source by id; an empty password keeps
    /// the stored one (edit forms do not echo the password back). Returns
    /// whether the connection identity (kind/base URL/username) changed, so
    /// callers can invalidate cached sessions (mac revision bump).
    pub fn update(&self, source: ServerSource) -> Result<bool, String> {
        let mut state = self.state.lock();
        let stored = state
            .servers
            .iter_mut()
            .find(|saved| saved.id == source.id)
            .ok_or_else(|| "The server configuration changed or was removed".to_string())?;
        let identity_changed = stored.kind != source.kind
            || stored.base_url != source.base_url
            || stored.username != source.username;
        let password = if source.password.is_empty() {
            stored.password.clone()
        } else {
            source.password
        };
        *stored = ServerSource { password, ..source };
        Self::persist(&state, &self.path)?;
        Ok(identity_changed)
    }

    /// mac `remove`: deletes by id; unknown ids are reported as stale.
    pub fn remove(&self, id: &str) -> Result<(), String> {
        let mut state = self.state.lock();
        let before = state.servers.len();
        state.servers.retain(|saved| saved.id != id);
        if state.servers.len() == before {
            return Err("The server configuration changed or was removed".into());
        }
        Self::persist(&state, &self.path)
    }

    /// Snapshot lookup used by the browse/play/test commands.
    pub fn source(&self, id: &str) -> Result<ServerSource, String> {
        self.state
            .lock()
            .servers
            .iter()
            .find(|saved| saved.id == id)
            .cloned()
            .ok_or_else(|| "Unknown server".to_string())
    }
}

/// Random v4 UUID without a crate dependency: 16 random bytes from the OS,
/// formatted per RFC 4122 with the version/variant bits forced.
pub fn new_uuid() -> String {
    let mut bytes = [0u8; 16];
    match getrandom_os(&mut bytes) {
        Ok(()) => {}
        Err(error) => {
            // Degenerate fallback: uuid uniqueness is cosmetic for the file
            // format; collisions would need the OS RNG to be broken.
            log::warn!("OS randomness unavailable, using time-based id: {error}");
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let counter = UUID_FALLBACK_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            for (index, slot) in bytes.iter_mut().enumerate() {
                *slot = ((nanos >> (index * 8)) as u8) ^ (counter as u8).wrapping_mul(31 + index as u8);
            }
        }
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

static UUID_FALLBACK_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

#[cfg(not(target_os = "windows"))]
fn getrandom_os(buffer: &mut [u8]) -> Result<(), String> {
    use std::io::Read;
    std::fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(buffer))
        .map_err(|error| error.to_string())
}

#[cfg(target_os = "windows")]
fn getrandom_os(buffer: &mut [u8]) -> Result<(), String> {
    use windows::Win32::Security::Cryptography::{
        BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG,
    };
    let result = unsafe {
        BCryptGenRandom(
            None,
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    if result.is_ok() {
        Ok(())
    } else {
        Err(format!("BCryptGenRandom failed: {:?}", result))
    }
}

/// Percent-encodes a password (or username) for embedding in a URL userinfo
/// section: unreserved characters stay, everything else becomes %XX (mac
/// `URLComponents.password` behavior, which encodes the same set).
pub fn percent_encode_userinfo(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Percent-decodes a URL path/href segment (`%XX` only; `+` is literal).
/// Invalid escapes yield None (mac `removingPercentEncoding` returns nil for
/// those; callers treat an undecodable href as unusable).
pub fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return None;
            }
            let high = hex_value(bytes[index + 1])?;
            let low = hex_value(bytes[index + 2])?;
            out.push((high << 4) | low);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// mac `WebDAV.validEscapes`: every `%` must be followed by two hex digits and
/// no control bytes appear.
pub fn valid_percent_escapes(value: &str) -> bool {
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return false;
            }
            match (hex_value(bytes[index + 1]), hex_value(bytes[index + 2])) {
                (Some(_), Some(_)) => index += 3,
                _ => return false,
            }
        } else if bytes[index] < 0x20 || bytes[index] == 0x7f {
            return false;
        } else {
            index += 1;
        }
    }
    true
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        _ => None,
    }
}

/// mac `ISODateParser.rfc1123` for WebDAV `getlastmodified`
/// ("Mon, 02 Oct 2026 18:00:00 GMT") → unix seconds. Only the fixed GMT
/// forms are accepted (servers send GMT per RFC 4918).
pub fn parse_rfc1123(text: &str) -> Option<i64> {
    let text = text.trim();
    // "Wdy, DD Mon YYYY HH:MM:SS GMT" — the day follows ", ".
    let rest = text.split_once(", ").map(|(_, rest)| rest)?;
    let mut parts = rest.split_ascii_whitespace();
    let day: u32 = parts.next()?.parse().ok()?;
    let month = month_index(parts.next()?)?;
    let year: i64 = parts.next()?.parse().ok()?;
    let time = parts.next()?;
    let zone = parts.next()?;
    if !zone.eq_ignore_ascii_case("gmt") || parts.next().is_some() {
        return None;
    }
    let mut time_parts = time.split(':');
    let hour: i64 = time_parts.next()?.parse().ok()?;
    let minute: i64 = time_parts.next()?.parse().ok()?;
    let second: i64 = time_parts.next()?.parse().ok()?;
    if time_parts.next().is_some() {
        return None;
    }
    days_from_civil(year, month as i64, day as i64)?
        .checked_mul(86_400)?
        .checked_add(hour * 3_600 + minute * 60 + second)
}

/// mac `ISODateParser.mlsdModify` for MLSD `modify` facts
/// ("YYYYMMDDHHMMSS" with optional ".sss"): strict 14 digits, range-checked,
/// returned as unix seconds (fractional part dropped, matching time_t).
pub fn parse_mlsd_modify(text: &str) -> Option<i64> {
    let (main, fraction) = match text.split_once('.') {
        Some((main, fraction)) => (main, Some(fraction)),
        None => (text, None),
    };
    if let Some(fraction) = fraction {
        // VLC ftp_mktime: at least one digit, digits only.
        if fraction.is_empty() || !fraction.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
    }
    let digits = main.as_bytes();
    if digits.len() != 14 || !digits.iter().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> i64 {
        digits[range].iter().fold(0, |acc, byte| acc * 10 + (byte - b'0') as i64)
    };
    let year = number(0..4);
    let month = number(4..6);
    let day = number(6..8);
    let hour = number(8..10);
    let minute = number(10..12);
    let second = number(12..14);
    if !(1000..=9999).contains(&year)
        || !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || !(0..=23).contains(&hour)
        || !(0..=59).contains(&minute)
        || !(0..=59).contains(&second)
    {
        return None;
    }
    days_from_civil(year, month, day)?
        .checked_mul(86_400)?
        .checked_add(hour * 3_600 + minute * 60 + second)
}

/// mac `ISODateParser.unixList`: classic LIST date columns — "Jan 1 12:00"
/// (recent, year-less: most recent matching date in the past, stepping back
/// one year when the current year lands in the future) or "Jan 1 2024"
/// (explicit year). The mac code evaluates this in the local timezone; std
/// has no local calendar, so the port uses UTC — the heuristic only decides
/// which year a display timestamp carries, and the boundary shifts by hours
/// at most.
pub fn parse_unix_list_date(month: &str, day: &str, year_or_time: &str) -> Option<i64> {
    let month = month_index(month)? as i64;
    let day: i64 = day.parse().ok()?;
    if !(1..=31).contains(&day) {
        return None;
    }
    let now = unix_now();
    if let Some((hour, minute)) = year_or_time.split_once(':') {
        let hour: i64 = hour.parse().ok()?;
        let minute: i64 = minute.parse().ok()?;
        if !(0..=23).contains(&hour) || !(0..=59).contains(&minute) {
            return None;
        }
        // Try the current year first; a future result steps back one year
        // (LIST omits the year for files newer than ~6 months).
        for candidate_year in [year_of(now), year_of(now) - 1] {
            if let Some(timestamp) = civil_timestamp(candidate_year, month, day, hour, minute) {
                if timestamp <= now {
                    return Some(timestamp);
                }
            }
        }
        None
    } else {
        let year: i64 = year_or_time.parse().ok()?;
        if year < 1900 {
            return None;
        }
        civil_timestamp(year, month, day, 0, 0)
    }
}

/// mac `Emby.parseItems` DateModified: ISO8601 with optional fractional
/// seconds and trailing Z (Emby/Jellyfin always send UTC).
pub fn parse_iso8601_utc(text: &str) -> Option<i64> {
    let text = text.trim();
    let (date_part, time_part) = text.split_once('T')?;
    let mut date_fields = date_part.split('-');
    let year: i64 = date_fields.next()?.parse().ok()?;
    // ISO8601 months are numeric ("10"), unlike RFC1123 month names.
    let month: i64 = date_fields.next()?.parse().ok()?;
    let day: i64 = date_fields.next()?.parse().ok()?;
    if date_fields.next().is_some() {
        return None;
    }
    let time_part = time_part.trim_end_matches('Z');
    let (time_body, fraction) = match time_part.split_once('.') {
        Some((body, fraction)) => (body, fraction),
        None => (time_part, ""),
    };
    if !fraction.is_empty() && !fraction.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let mut time_fields = time_body.split(':');
    let hour: i64 = time_fields.next()?.parse().ok()?;
    let minute: i64 = time_fields.next()?.parse().ok()?;
    let second: i64 = time_fields.next()?.parse().ok()?;
    if time_fields.next().is_some() {
        return None;
    }
    if !(1..=31).contains(&day) || !(0..=23).contains(&hour) || !(0..=59).contains(&minute) {
        return None;
    }
    if !(0..=60).contains(&second) {
        return None;
    }
    days_from_civil(year, month, day)?
        .checked_mul(86_400)?
        .checked_add(hour * 3_600 + minute * 60 + second)
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

/// The UTC year of a unix timestamp (inverse of days_from_civil).
fn year_of(timestamp: i64) -> i64 {
    let days = timestamp.div_euclid(86_400);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    // year_of_era counts from March; Jan/Feb belong to the next civil year.
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    if day_of_year >= 306 {
        year + 1 // Jan 1 (day 306 from March 1) or later in the civil sense
    } else {
        year
    }
}

/// UTC midnight-based civil timestamp; used by the LIST heuristic.
fn civil_timestamp(year: i64, month: i64, day: i64, hour: i64, minute: i64) -> Option<i64> {
    days_from_civil(year, month, day)?
        .checked_mul(86_400)?
        .checked_add(hour * 3_600 + minute * 60)
}

fn month_index(name: &str) -> Option<u32> {
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    MONTHS
        .iter()
        .position(|candidate| candidate.eq_ignore_ascii_case(name))
        .map(|index| index as u32 + 1)
}

/// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`), valid for the
/// whole practical year range without a calendar crate.
fn days_from_civil(year: i64, month: i64, day: i64) -> Option<i64> {
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}
