//! Emby/Jellyfin client: AuthenticateByName with the X-Emby-Authorization
//! header, item browsing, and direct-stream playback URLs.
//!
//! Logic follows the macOS `Emby.swift`: authentication retries with the
//! `/emby/` path prefix when the unprefixed endpoint 404s (two server
//! generations; an explicit `.../emby` base URL is never double-prefixed);
//! browse sends `X-Emby-Token` and re-authenticates once on 401; playback
//! URLs are `{base}/Videos/{id}/stream?Static=true&api_key=...` for video and
//! `{base}/Audio/{id}/universal?api_key=...` for audio. Tokens are cached in
//! memory per source id (the mac app persists them in the Keychain; the port
//! re-authenticates on restart instead — a one-request cost per session).
use parking_lot::Mutex;
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Arc;

use super::dav::ParsedUrl;
use super::model::{kind_uses_emby_client, parse_iso8601_utc, MediaItem, ServerSource};

#[derive(Debug)]
pub enum EmbyError {
    BadUrl,
    Auth,
    Http(u16),
}

impl std::fmt::Display for EmbyError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EmbyError::BadUrl => write!(formatter, "Invalid server URL"),
            EmbyError::Auth => {
                write!(formatter, "Authentication failed — check username and password")
            }
            EmbyError::Http(code) => write!(formatter, "Server returned HTTP {code}"),
        }
    }
}

/// mac `EmbyClient.Session`.
#[derive(Clone, Debug)]
pub struct Session {
    pub user_id: String,
    pub token: String,
    /// Whether API paths carry the `/emby` prefix (mac `usesEmbyPrefix`).
    pub uses_emby_prefix: bool,
}

/// In-memory token cache: source id → session. The mac client binds cached
/// sessions to a configuration revision so an edited server invalidates them;
/// the port keys the cache by source id and clears the entry on every
/// update/remove through `invalidate`, which gives the same guarantee.
#[derive(Default)]
pub struct SessionCache(Mutex<HashMap<String, Session>>);

impl SessionCache {
    pub fn shared() -> Arc<Self> {
        static SHARED: std::sync::OnceLock<Arc<SessionCache>> = std::sync::OnceLock::new();
        SHARED.get_or_init(|| Arc::new(SessionCache::default())).clone()
    }

    pub fn get(&self, source_id: &str) -> Option<Session> {
        self.0.lock().get(source_id).cloned()
    }

    pub fn put(&self, source_id: &str, session: Session) {
        self.0.lock().insert(source_id.to_string(), session);
    }

    pub fn invalidate(&self, source_id: &str) {
        self.0.lock().remove(source_id);
    }
}

/// mac `hasExplicitPrefix`: the base URL path already ends with `/emby`.
fn has_explicit_prefix(source: &ServerSource) -> bool {
    ParsedUrl::parse(&source.base_url)
        .map(|parsed| {
            parsed
                .path
                .trim_end_matches('/')
                .rsplit('/')
                .next()
                .is_some_and(|segment| segment.eq_ignore_ascii_case("emby"))
        })
        .unwrap_or(false)
}

/// mac `apiURL`: base origin + optional `/emby` prefix + path components.
/// Components are validated (no empty/./../, no separators) like the mac code.
fn api_url(source: &ServerSource, uses_prefix: bool, components: &[&str]) -> Result<String, EmbyError> {
    let parsed = ParsedUrl::parse(&source.base_url).ok_or(EmbyError::BadUrl)?;
    if !matches!(parsed.scheme.as_str(), "http" | "https") {
        return Err(EmbyError::BadUrl);
    }
    let mut base = parsed.path.trim_end_matches('/').to_string();
    if uses_prefix && !has_explicit_prefix(source) {
        base.push_str("/emby");
    }
    let mut url = format!("{}{}", parsed.origin(), base);
    for component in components {
        if component.is_empty()
            || *component == "."
            || *component == ".."
            || component.contains('/')
            || component.contains('\\')
        {
            return Err(EmbyError::BadUrl);
        }
        url.push('/');
        url.push_str(&encode_path_segment(component));
    }
    Ok(url)
}

/// Test seam for `api_url` (network-free URL composition tests).
#[cfg(test)]
pub fn test_api_url(
    source: &ServerSource,
    uses_prefix: bool,
    components: &[&str],
) -> Result<String, EmbyError> {
    api_url(source, uses_prefix, components)
}

fn encode_path_segment(segment: &str) -> String {
    let mut out = String::with_capacity(segment.len());
    for byte in segment.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn encode_query(value: &str) -> String {
    // api_key tokens and item ids are ASCII; encode defensively anyway.
    encode_path_segment(value)
}

fn agent() -> ureq::Agent {
    // Tokens and password-bearing POST bodies must not follow redirects
    // (mac NoRedirect delegate); ureq's redirects(0) gives the same behavior.
    ureq::AgentBuilder::new()
        .redirects(0)
        .timeout(std::time::Duration::from_secs(30))
        .build()
}

/// mac `authenticated`: cached session first, otherwise AuthenticateByName
/// with the 404 → `/emby/` prefix retry.
pub fn authenticate(source: &ServerSource) -> Result<Session, EmbyError> {
    if let Some(session) = SessionCache::shared().get(&source.id) {
        if !session.token.is_empty() && !session.user_id.is_empty() {
            return Ok(session);
        }
    }
    if source.username.is_empty() || source.password.is_empty() {
        return Err(EmbyError::Auth);
    }
    let body = serde_json::json!({ "Username": source.username, "Pw": source.password }).to_string();
    let mut uses_prefix = false;
    let attempt = |prefix: bool| -> Result<(u16, String), EmbyError> {
        let url = api_url(source, prefix, &["Users", "AuthenticateByName"])?;
        let response = agent()
            .post(&url)
            .set("Content-Type", "application/json")
            .set(
                "X-Emby-Authorization",
                "MediaBrowser Client=\"BrushLLM Player\", Device=\"Windows\", DeviceId=\"BrushLLMPlayer\", Version=\"0.1\"",
            )
            // send_json needs the "json" feature; the body is already
            // serialized, so send it as a string with the JSON content type.
            .send_string(body.as_str());
        match response {
            Ok(response) => {
                let status = response.status();
                let text = response.into_string().unwrap_or_default();
                Ok((status, text))
            }
            Err(ureq::Error::Status(code, _)) => Ok((code, String::new())),
            Err(error) => {
                log::warn!("Emby auth request failed: {error}");
                Err(EmbyError::Http(0))
            }
        }
    };
    let (mut status, mut text) = attempt(uses_prefix)?;
    if status == 404 && !uses_prefix && !has_explicit_prefix(source) {
        uses_prefix = true;
        let (retried_status, retried_text) = attempt(uses_prefix)?;
        status = retried_status;
        text = retried_text;
    }
    if !(200..300).contains(&status) {
        if status == 401 {
            return Err(EmbyError::Auth);
        }
        return Err(EmbyError::Http(status));
    }
    let session = parse_auth_response(&text).ok_or(EmbyError::Auth)?;
    let session = Session {
        user_id: session.user_id,
        token: session.token,
        uses_emby_prefix: uses_prefix,
    };
    SessionCache::shared().put(&source.id, session.clone());
    Ok(session)
}

#[derive(Deserialize)]
struct AuthResponse {
    #[serde(rename = "AccessToken")]
    access_token: Option<String>,
    #[serde(rename = "User")]
    user: Option<AuthUser>,
}
#[derive(Deserialize)]
struct AuthUser {
    #[serde(rename = "Id")]
    id: Option<String>,
}

fn parse_auth_response(text: &str) -> Option<Session> {
    let decoded: AuthResponse = serde_json::from_str(text).ok()?;
    let token = decoded.access_token.filter(|token| !token.is_empty())?;
    let user_id = decoded
        .user
        .and_then(|user| user.id)
        .filter(|id| !id.is_empty())?;
    Some(Session {
        user_id,
        token,
        uses_emby_prefix: false,
    })
}

/// Test seam for `parse_auth_response` (network-free auth JSON tests).
#[cfg(test)]
pub fn test_parse_auth_response(text: &str) -> Option<Session> {
    parse_auth_response(text)
}

/// mac `list`: GET /Users/{uid}/Items?ParentId=...&Fields=Size,DateModified,
/// MediaType&SortBy=SortName with the token header; one re-auth on 401.
pub fn list(source: &ServerSource, parent_id: &str) -> Result<Vec<MediaItem>, EmbyError> {
    let mut session = authenticate(source)?;
    for attempt in 0..=1 {
        let mut url = api_url(
            source,
            session.uses_emby_prefix,
            &["Users", &session.user_id, "Items"],
        )?;
        let mut query: Vec<String> = Vec::new();
        if !parent_id.is_empty() {
            query.push(format!("ParentId={}", encode_query(parent_id)));
        }
        query.push("Fields=Size,DateModified,MediaType".to_string());
        query.push("SortBy=SortName".to_string());
        url.push('?');
        url.push_str(&query.join("&"));
        let response = agent()
            .get(&url)
            .set("X-Emby-Token", &session.token)
            .call();
        let (status, text) = match response {
            Ok(response) => {
                let status = response.status();
                let text = response.into_string().unwrap_or_default();
                (status, text)
            }
            Err(ureq::Error::Status(code, _)) => (code, String::new()),
            Err(error) => {
                log::warn!("Emby items request failed: {error}");
                return Err(EmbyError::Http(0));
            }
        };
        if status == 401 {
            if attempt == 0 {
                // Token expired: drop the cache entry and re-authenticate once.
                SessionCache::shared().invalidate(&source.id);
                session = authenticate(source)?;
                continue;
            }
            return Err(EmbyError::Auth);
        }
        if !(200..300).contains(&status) {
            return Err(EmbyError::Http(status));
        }
        return parse_items(&text);
    }
    Err(EmbyError::Auth)
}

/// mac `parseItems`: Type=Folder-family → directory; MediaType audio/video
/// (falling back to the item Type name for typed items without MediaType);
/// folders never carry a media type.
pub fn parse_items(text: &str) -> Result<Vec<MediaItem>, EmbyError> {
    #[derive(Deserialize)]
    struct ItemsResponse {
        #[serde(rename = "Items")]
        items: Vec<Item>,
    }
    #[derive(Deserialize)]
    struct Item {
        #[serde(rename = "Name")]
        name: Option<String>,
        #[serde(rename = "Id")]
        id: Option<String>,
        #[serde(rename = "Type")]
        item_type: Option<String>,
        #[serde(rename = "MediaType")]
        media_type: Option<String>,
        #[serde(rename = "Size")]
        size: Option<i64>,
        #[serde(rename = "DateModified")]
        date_modified: Option<String>,
        #[serde(rename = "IsFolder")]
        is_folder: Option<bool>,
    }
    let decoded: ItemsResponse =
        serde_json::from_str(text).map_err(|_| EmbyError::Http(0))?;
    const FOLDER_TYPES: [&str; 7] = [
        "Folder",
        "CollectionFolder",
        "UserView",
        "Series",
        "Season",
        "MusicAlbum",
        "MusicArtist",
    ];
    let items = decoded
        .items
        .into_iter()
        .filter_map(|item| {
            let id = item.id.filter(|id| !id.is_empty())?;
            let name = item.name?;
            let is_directory = item.is_folder.unwrap_or(
                item.item_type
                    .as_deref()
                    .is_some_and(|kind| FOLDER_TYPES.contains(&kind)),
            );
            let media_type = if is_directory {
                None
            } else {
                match item.media_type.as_deref().map(str::to_ascii_lowercase).as_deref() {
                    Some("audio") => Some("audio".to_string()),
                    Some("video") => Some("video".to_string()),
                    Some(_) => None,
                    None => match item.item_type.as_deref() {
                        Some("Audio") => Some("audio".to_string()),
                        Some("Movie") | Some("Episode") | Some("Video") | Some("MusicVideo") => {
                            Some("video".to_string())
                        }
                        _ => None,
                    },
                }
            };
            Some(MediaItem {
                id,
                name,
                is_directory,
                size: item.size.unwrap_or(0).max(0),
                modified_at: item
                    .date_modified
                    .as_deref()
                    .and_then(parse_iso8601_utc)
                    .map(|seconds| seconds.to_string()),
                media_type,
            })
        })
        .collect();
    Ok(items)
}

/// mac `playbackURL`: video → /Videos/{id}/stream?Static=true&api_key=...,
/// audio → /Audio/{id}/universal?api_key=... (Static streams remux nothing —
/// the file bytes go straight to mpv).
pub fn playback_url(source: &ServerSource, item: &MediaItem) -> Result<String, EmbyError> {
    if !kind_uses_emby_client(&source.kind) {
        return Err(EmbyError::BadUrl);
    }
    let media_type = item.media_type.as_deref().ok_or(EmbyError::BadUrl)?;
    if item.is_directory || !matches!(media_type, "audio" | "video") {
        return Err(EmbyError::BadUrl);
    }
    let session = authenticate(source)?;
    let (components, static_param) = if media_type == "audio" {
        (vec!["Audio", &item.id, "universal"], false)
    } else {
        (vec!["Videos", &item.id, "stream"], true)
    };
    let mut url = api_url(source, session.uses_emby_prefix, &components)?;
    url.push('?');
    if static_param {
        url.push_str("Static=true&");
    }
    url.push_str(&format!("api_key={}", encode_query(&session.token)));
    Ok(url)
}
