//! WebDAV client: PROPFIND Depth:1 listings, multistatus XML parsing and
//! credential-bearing playback URLs.
//!
//! Protocol behavior follows the macOS `WebDAV.swift` (which itself mirrors
//! VLC `webdav.c`): request displayname/resourcetype/getcontentlength/
//! getlastmodified; the self entry is excluded by comparing the href path
//! against the request path (never by position — the mac-side fix for servers
//! that reorder or omit it); hrefs are resolved against the request URL and
//! percent-decoded; propstat blocks with a non-2xx status contribute nothing.
//! Playback URLs embed Basic credentials (mpv's http backend sends them and
//! follows 302 redirects itself, which is how 115/OpenList playback works).
use base64::Engine as _;
use quick_xml::events::Event;
use quick_xml::Reader;

use super::model::{
    parse_rfc1123, percent_decode, percent_encode_userinfo, valid_percent_escapes, MediaItem,
    ServerSource,
};

#[derive(Debug)]
pub enum DavError {
    BadUrl,
    Http(u16),
    Parse,
}

impl std::fmt::Display for DavError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DavError::BadUrl => write!(formatter, "Invalid WebDAV URL"),
            DavError::Http(code) => write!(formatter, "Server returned HTTP {code}"),
            DavError::Parse => write!(formatter, "Could not parse the server response"),
        }
    }
}

/// A minimal URL split used across the clients: scheme://host[:port] plus the
/// percent-encoded path. `ServerSource.base_url` is user-entered, so parsing
/// is deliberately strict (scheme + host required, no credentials/query).
#[derive(Clone, Debug, PartialEq)]
pub struct ParsedUrl {
    pub scheme: String,
    pub host: String,
    pub port: u16,
    /// Percent-encoded path, always starting with `/` (empty becomes "/").
    pub path: String,
}

impl ParsedUrl {
    /// Strict split of a user-entered URL. The DAV scheme aliases
    /// (dav/webdav/davs/webdavs, VLC shortcuts) normalize to http/https so
    /// `origin()` always yields a real HTTP origin; `ftp` stays for the FTP
    /// client.
    pub fn parse(url: &str) -> Option<Self> {
        let url = url.trim();
        let (raw_scheme, rest) = url.split_once("://")?;
        let scheme = match raw_scheme.to_ascii_lowercase().as_str() {
            "dav" | "webdav" => "http".to_string(),
            "davs" | "webdavs" => "https".to_string(),
            other => other.to_string(),
        };
        let (authority, path) = match rest.split_once('/') {
            Some((authority, path)) => (authority, format!("/{path}")),
            None => (rest, "/".to_string()),
        };
        let authority = authority.split('@').next_back()?; // drop userinfo
        let authority = authority.split('?').next()?; // drop stray query
        let (host, port) = match authority.rsplit_once(':') {
            Some((host, port)) if !host.is_empty() && !port.is_empty() => {
                (host, port.parse::<u16>().ok())
            }
            _ => (authority, None),
        };
        if host.is_empty() || host.contains(['[', ']', '/']) {
            return None;
        }
        let default_port = match scheme.as_str() {
            "https" => 443,
            "http" => 80,
            "ftp" => 21,
            _ => return None,
        };
        Some(ParsedUrl {
            scheme,
            host: host.to_string(),
            port: port.unwrap_or(default_port),
            path: if path.is_empty() { "/".into() } else { path },
        })
    }

    /// scheme://host[:port] without the path — the mac `origin(of:)`.
    /// Schemes are normalized at parse time, so this is always http/https/ftp.
    pub fn origin(&self) -> String {
        let default_port = match self.scheme.as_str() {
            "https" => 443,
            "http" => 80,
            _ => 21,
        };
        if self.port == default_port {
            format!("{}://{}", self.scheme, self.host)
        } else {
            format!("{}://{}:{}", self.scheme, self.host, self.port)
        }
    }

    /// mac `sameOrigin`: scheme + host (case-insensitive) + effective port.
    /// Kept for callers that need origin checks (e.g. redirect guards).
    #[allow(dead_code)]
    pub fn same_origin(&self, other: &ParsedUrl) -> bool {
        self.scheme == other.scheme
            && self.host.eq_ignore_ascii_case(&other.host)
            && self.port == other.port
    }
}

/// mac `WebDAVClient.basePath`: the browse root is the base URL's path.
pub fn base_path(source: &ServerSource) -> String {
    match ParsedUrl::parse(&source.base_url) {
        Some(parsed) => normalize_path(&parsed.path),
        None => "/".to_string(),
    }
}

/// mac `normalizedPath`: strip trailing slashes (keep a lone "/").
pub fn normalize_path(path: &str) -> String {
    let mut result = if path.is_empty() { "/".to_string() } else { path.to_string() };
    while result.len() > 1 && result.ends_with('/') {
        result.pop();
    }
    result
}

/// mac `authorization`: Basic base64(user:password) when a username exists.
fn authorization(source: &ServerSource) -> Option<String> {
    if source.username.is_empty() {
        return None;
    }
    let credentials = format!("{}:{}", source.username, source.password);
    Some(format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(credentials.as_bytes())
    ))
}

/// PROPFIND Depth:1 against `origin + path`; returns the children of `path`
/// (the self entry is dropped during parsing).
pub fn list(source: &ServerSource, path: &str) -> Result<Vec<MediaItem>, DavError> {
    let parsed = ParsedUrl::parse(&source.base_url).ok_or(DavError::BadUrl)?;
    let path = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    };
    let url = format!("{}{}", parsed.origin(), encode_request_path(&path));
    let body = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop>
<d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/>
</d:prop></d:propfind>"#;
    let agent = ureq::AgentBuilder::new()
        .redirects(0) // listings must not move to another origin
        .timeout(std::time::Duration::from_secs(30))
        .build();
    let mut request = agent
        .request("PROPFIND", &url)
        .set("Depth", "1")
        .set("Content-Type", "application/xml")
        .set("Accept", "application/xml, text/xml");
    if let Some(value) = authorization(source) {
        request = request.set("Authorization", &value);
    }
    let response = map_ureq(request.send_string(body))?;
    let text = response.into_string().map_err(|_| DavError::Http(0))?;
    parse_listing(&text, &path)
}

/// ureq surfaces non-2xx as `Error::Status(code, response)`; redirects(0)
/// makes 3xx arrive the same way. Network/IO failures map to Http(0).
fn map_ureq(result: Result<ureq::Response, ureq::Error>) -> Result<ureq::Response, DavError> {
    match result {
        Ok(response) => Ok(response),
        Err(ureq::Error::Status(code, _)) => Err(DavError::Http(code)),
        Err(error) => {
            log::warn!("WebDAV request failed: {error}");
            Err(DavError::Http(0))
        }
    }
}

/// mac `playbackURL`: origin + path with the credentials percent-encoded into
/// the userinfo section (mpv's http backend sends them as Basic auth and
/// follows redirects itself — 115/OpenList 302s need no client handling).
pub fn playback_url(source: &ServerSource, path: &str) -> Option<String> {
    let parsed = ParsedUrl::parse(&source.base_url)?;
    let path = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    };
    let path = encode_request_path(&path);
    let default_port = if parsed.scheme == "https" { 443 } else { 80 };
    let port = if parsed.port == default_port {
        String::new()
    } else {
        format!(":{}", parsed.port)
    };
    if source.username.is_empty() {
        Some(format!("{}://{}{}{}", parsed.scheme, parsed.host, port, path))
    } else {
        let user = percent_encode_userinfo(&source.username);
        let password = percent_encode_userinfo(&source.password);
        Some(format!(
            "{}://{user}:{password}@{}{}{}",
            parsed.scheme, parsed.host, port, path
        ))
    }
}

/// Re-encodes a stored (already percent-encoded) path for the request line:
/// `%` stays, characters that are not URL-path-safe become %XX.
fn encode_request_path(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for byte in path.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' | b'%'
            | b'!' | b'$' | b'&' | b'\'' | b'(' | b')' | b'*' | b'+' | b',' | b';' | b'='
            | b':' | b'@' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// One `<response>` worth of accumulated properties (mac `Properties`).
#[derive(Default)]
struct Entry {
    href: Option<String>,
    displayname: Option<String>,
    size: Option<i64>,
    directory: Option<bool>,
    modified: Option<i64>,
}

impl Entry {
    fn reset(&mut self) {
        *self = Self::default();
    }
}

/// mac `parseListing` + VLC `ParseMultistatus`: a pull parse of the
/// multistatus body. `request_path` is the percent-encoded path that was
/// requested; the self entry is recognized by comparing decoded href paths
/// (never by position). Text inside a leaf is attributed through a tag stack.
pub fn parse_listing(xml: &str, request_path: &str) -> Result<Vec<MediaItem>, DavError> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut items = Vec::new();
    let mut seen: Vec<String> = Vec::new();

    let mut entry = Entry::default();
    let mut response_status: Option<u16> = None;
    let mut propstat_ok = false;
    let mut propstat_status: Option<u16> = None;
    let mut in_propstat = false;
    let mut in_resourcetype = false;
    let mut is_multistatus = false;
    let mut depth = 0usize;
    let mut stack: Vec<String> = Vec::new();

    let mut buffer = Vec::new();
    loop {
        match reader.read_event_into(&mut buffer) {
            Ok(Event::Start(event)) => {
                let name = String::from_utf8_lossy(event.name().as_ref())
                    .rsplit(':')
                    .next()
                    .unwrap_or_default()
                    .to_string();
                depth += 1;
                if depth == 1 {
                    is_multistatus = name == "multistatus";
                    if !is_multistatus {
                        return Err(DavError::Parse);
                    }
                }
                match name.as_str() {
                    "response" => {
                        entry.reset();
                        response_status = None;
                        propstat_ok = false;
                    }
                    "propstat" => {
                        in_propstat = true;
                        propstat_status = None;
                    }
                    "resourcetype" => {
                        if in_propstat {
                            in_resourcetype = true;
                            entry.directory.get_or_insert(false); // empty = file
                        }
                    }
                    "collection" => {
                        if in_resourcetype {
                            entry.directory = Some(true);
                        }
                    }
                    _ => {}
                }
                stack.push(name);
            }
            Ok(Event::Empty(event)) => {
                let name = String::from_utf8_lossy(event.name().as_ref())
                    .rsplit(':')
                    .next()
                    .unwrap_or_default()
                    .to_string();
                if name == "resourcetype" && in_propstat {
                    entry.directory.get_or_insert(false);
                }
                if name == "collection" && in_resourcetype {
                    entry.directory = Some(true);
                }
            }
            Ok(Event::Text(event)) => {
                let text = event.unescape().map_err(|_| DavError::Parse)?;
                let text = text.trim();
                if text.is_empty() {
                    continue;
                }
                // Attribute to the innermost open element (the stack top).
                let tag = stack.last().map(String::as_str);
                match tag {
                    Some("href") => entry.href.get_or_insert_with(|| text.to_string()),
                    Some("displayname") => {
                        entry.displayname.get_or_insert_with(|| text.to_string())
                    }
                    Some("getcontentlength") => {
                        if let Some(value) = text.parse::<i64>().ok() {
                            entry.size = Some(value.max(0));
                        }
                        ""
                    }
                    Some("getlastmodified") => {
                        if let Some(seconds) = parse_rfc1123(text) {
                            entry.modified = Some(seconds);
                        }
                        ""
                    }
                    Some("status") => {
                        // "HTTP/1.1 200 OK" — the code is the second token
                        // (mac status parsing); parent decides propstat/response.
                        let code = text
                            .split_ascii_whitespace()
                            .nth(1)
                            .and_then(|value| value.parse::<u16>().ok());
                        if let Some(code) = code {
                            if stack.iter().rev().nth(1).is_some_and(|parent| parent == "propstat")
                            {
                                propstat_status = Some(code);
                            } else {
                                response_status = Some(code);
                            }
                        }
                        ""
                    }
                    _ => "",
                };
            }
            Ok(Event::CData(event)) => {
                let text = String::from_utf8_lossy(event.as_ref()).trim().to_string();
                if !text.is_empty() && stack.last().map(String::as_str) == Some("displayname") {
                    entry.displayname.get_or_insert(text);
                }
            }
            Ok(Event::End(event)) => {
                let name = String::from_utf8_lossy(event.name().as_ref())
                    .rsplit(':')
                    .next()
                    .unwrap_or_default()
                    .to_string();
                match name.as_str() {
                    "resourcetype" => in_resourcetype = false,
                    "propstat" => {
                        if propstat_status.is_some_and(|status| (200..300).contains(&status)) {
                            propstat_ok = true;
                        }
                        in_propstat = false;
                        propstat_status = None;
                    }
                    "response" => {
                        if propstat_ok
                            && response_status.map_or(true, |status| (200..300).contains(&status))
                        {
                            if let Some(item) = entry.take_item(request_path, &mut seen) {
                                items.push(item);
                            }
                        }
                    }
                    _ => {}
                }
                stack.pop();
                depth = depth.saturating_sub(1);
            }
            Ok(Event::Eof) => {
                // Pull parsing does not validate nesting: unclosed elements
                // are malformed XML (mac XMLParser.parse() would fail).
                if depth > 0 {
                    return Err(DavError::Parse);
                }
                break;
            }
            // Comments, declarations, PIs and DOCTYPEs carry no properties.
            Ok(_) => {}
            Err(_) => return Err(DavError::Parse),
        }
        buffer.clear();
    }
    if !is_multistatus {
        return Err(DavError::Parse);
    }
    Ok(items)
}

impl Entry {
    /// mac response-end handling: build the item, dropping the self entry and
    /// duplicates. Returns None for unusable entries (no href, foreign
    /// origin, undecodable path).
    fn take_item(&mut self, request_path: &str, seen: &mut Vec<String>) -> Option<MediaItem> {
        let href = self.href.take()?;
        let path = href_path(&href, request_path)?;
        // Self entry: the href resolves to the requested directory itself
        // (decoded-path comparison; a trailing slash on a collection href is
        // tolerated, matching VLC IsSelfHref).
        let decoded_self = percent_decode(&normalize_path(request_path));
        let decoded_path = percent_decode(&path);
        if decoded_self.is_some() && decoded_path == decoded_self {
            return None;
        }
        if seen.iter().any(|entry| entry == &path) {
            return None;
        }
        seen.push(path.clone());
        let fallback = percent_decode(&path)?
            .rsplit('/')
            .next()
            .unwrap_or_default()
            .to_string();
        Some(MediaItem {
            id: path,
            name: self
                .displayname
                .take()
                .filter(|name| !name.is_empty())
                .unwrap_or(fallback),
            is_directory: self.directory.take().unwrap_or(false),
            size: self.size.take().unwrap_or(0),
            modified_at: self.modified.take().map(|seconds| seconds.to_string()),
            media_type: None,
        })
    }
}

/// mac `hrefPath`: resolve the href (absolute URL, absolute path or relative
/// segment) against the request path, keep only path-only results, and
/// normalize trailing slashes. Absolute URLs are accepted when their
/// authority matches the request's default-port origin form.
fn href_path(href: &str, request_path: &str) -> Option<String> {
    if href.is_empty() || !valid_percent_escapes(href) {
        return None;
    }
    if href.contains(['\0', '?', '#']) {
        return None;
    }
    if href.starts_with("http://") || href.starts_with("https://") {
        // Absolute URL form: strip scheme://authority, validate the port
        // against the scheme default (the request origin is the base URL's
        // origin, which the browse flow guarantees).
        let rest = href
            .strip_prefix("http://")
            .or_else(|| href.strip_prefix("https://"))?;
        let (authority, path) = rest.split_once('/')?;
        let authority = authority
            .rsplit_once('@')
            .map(|(_, host)| host)
            .unwrap_or(authority);
        if let Some((_host, port)) = authority.rsplit_once(':') {
            if port != "80" && port != "443" {
                return None;
            }
        }
        let path = if path.is_empty() { "/" } else { path };
        return Some(normalize_path(&format!("/{path}")));
    }
    if let Some(relative) = href.strip_prefix('/') {
        // Absolute-path form: use as-is.
        return Some(normalize_path(&format!("/{relative}")));
    }
    // Relative form: resolve against the request directory.
    let base_dir = match request_path.rfind('/') {
        Some(0) | None => "/".to_string(),
        Some(index) => request_path[..index].to_string(),
    };
    let resolved = if base_dir == "/" {
        format!("/{href}")
    } else {
        format!("{base_dir}/{href}")
    };
    Some(normalize_path(&resolved))
}
