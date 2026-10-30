//! FTP client: a hand-written control connection over `TcpStream` (FTP is a
//! cleartext protocol, so no TLS stack is needed), PASV data connections,
//! MLSD-preferred listings with a LIST fallback.
//!
//! Logic follows the macOS `FTP.swift` (which mirrors VLC `ftp.c`): USER/PASS
//! login (230 short-circuit, 331→PASS), TYPE I, PASV with the 227 reply
//! parsed for the data port (connecting back to the *control* host — PASV
//! addresses are hints, often a private address behind NAT), MLSD first with
//! a LIST fallback when the server rejects MLSD, unix line parsing with the
//! 6-month year heuristic. Playback URLs embed credentials for mpv's native
//! ftp protocol.
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use super::dav::ParsedUrl;
use super::model::{
    parse_mlsd_modify, parse_unix_list_date, percent_encode_userinfo, MediaItem, ServerSource,
};

#[derive(Debug)]
pub enum FtpError {
    BadUrl,
    Connection(String),
    Login,
    Listing,
    Timeout,
    ResponseTooLarge,
}

impl std::fmt::Display for FtpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FtpError::BadUrl => write!(formatter, "Invalid FTP URL"),
            FtpError::Connection(detail) => write!(formatter, "Could not connect: {detail}"),
            FtpError::Login => write!(formatter, "Login failed — check username and password"),
            FtpError::Listing => write!(formatter, "Could not read the directory listing"),
            FtpError::Timeout => write!(formatter, "The FTP server did not respond in time"),
            FtpError::ResponseTooLarge => {
                write!(formatter, "The FTP directory listing is too large")
            }
        }
    }
}

const READ_TIMEOUT: Duration = Duration::from_secs(10);
const REPLY_LIMIT: usize = 1024 * 1024;
const DATA_LIMIT: usize = 16 * 1024 * 1024;

/// mac `FTPClient.rootPath`: the browse root is the base URL's path.
pub fn root_path(source: &ServerSource) -> String {
    match ParsedUrl::parse(&source.base_url) {
        Some(parsed) => {
            let mut path = parsed.path.clone();
            while path.len() > 1 && path.ends_with('/') {
                path.pop();
            }
            if path.is_empty() {
                "/".to_string()
            } else {
                path
            }
        }
        None => "/".to_string(),
    }
}

/// mac `FTPClient.playbackURL`: ftp://user:pass@host:port/path with the
/// credentials percent-encoded (mpv's native ftp protocol).
pub fn playback_url(source: &ServerSource, path: &str) -> Option<String> {
    let parsed = ParsedUrl::parse(&source.base_url)?;
    if parsed.scheme != "ftp" {
        return None;
    }
    let path = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    };
    let user = if source.username.is_empty() {
        "anonymous".to_string()
    } else {
        percent_encode_userinfo(&source.username)
    };
    let password = percent_encode_userinfo(&source.password);
    Some(format!(
        "ftp://{user}:{password}@{}:{}{}",
        parsed.host, parsed.port, path
    ))
}

/// Connects, logs in and lists `path`. Blocking; callers run this inside
/// `spawn_blocking` (browse is a user-triggered call).
pub fn list(source: &ServerSource, path: &str) -> Result<Vec<MediaItem>, FtpError> {
    let parsed = ParsedUrl::parse(&source.base_url).ok_or(FtpError::BadUrl)?;
    if parsed.scheme != "ftp" {
        return Err(FtpError::BadUrl);
    }
    let username = if source.username.is_empty() {
        "anonymous".to_string()
    } else {
        source.username.clone()
    };
    let mut session = FtpSession::connect(&parsed.host, parsed.port)?;
    session.login(&username, &source.password)?;
    let raw = session.list_directory(path)?;
    let listing = parse_listing(&raw).ok_or(FtpError::Listing)?;
    Ok(items_under(listing, path))
}

/// mac `FTPClient.items(under:)`: prefix child ids with the browsed path and
/// drop "." / ".." (kept for parity even though the parsers already filter).
pub fn items_under(listing: Vec<MediaItem>, path: &str) -> Vec<MediaItem> {
    let prefix = if path.ends_with('/') {
        path.to_string()
    } else {
        format!("{path}/")
    };
    listing
        .into_iter()
        .filter(|item| item.name != "." && item.name != "..")
        .map(|mut item| {
            item.id = format!("{}{}", prefix, item.name);
            item
        })
        .collect()
}

/// mac `parseListing`: try MLSD then unix LIST per line; at least one parsed
/// line is required (an empty listing is a valid empty directory).
pub fn parse_listing(raw: &str) -> Option<Vec<MediaItem>> {
    let lines: Vec<String> = raw
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .split('\n')
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect();
    if lines.is_empty() {
        return Some(Vec::new());
    }
    let mut items = Vec::new();
    let mut parsed_any = false;
    for line in lines {
        if let Some(item) = parse_mlsd_line(&line).or_else(|| parse_unix_line(&line)) {
            parsed_any = true;
            if item.name != "." && item.name != ".." {
                items.push(item);
            }
        }
    }
    if parsed_any {
        Some(items)
    } else {
        None
    }
}

/// mac `parseMLSDLine`: "type=file;size=1234;modify=20260101120000; name".
/// type must be file/dir/cdir/pdir (or os.unix=slink); cdir/pdir map to
/// "."/".."; the name may not contain separators.
fn parse_mlsd_line(line: &str) -> Option<MediaItem> {
    let separator = line.find(' ')?;
    let raw_facts = &line[..separator];
    if !raw_facts.ends_with(';') {
        return None;
    }
    let mut facts: Vec<(String, String)> = Vec::new();
    for fact in raw_facts.split(';') {
        if fact.is_empty() {
            continue;
        }
        let (key, value) = fact.split_once('=')?;
        facts.push((key.to_ascii_lowercase(), value.to_string()));
    }
    let fact = |name: &str| -> Option<&str> {
        facts
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
    };
    let type_value = fact("type")?.to_ascii_lowercase();
    let is_link = type_value.starts_with("os.unix=slink");
    let is_directory = matches!(type_value.as_str(), "dir" | "cdir" | "pdir");
    if !is_directory && type_value != "file" && !is_link {
        return None;
    }
    let name = &line[separator + 1..];
    if name.is_empty() || name.contains('/') || name.contains('\0') {
        return None;
    }
    let size: i64 = fact("size")
        .and_then(|value| value.parse::<i64>().ok())
        .map(|value| value.max(0))
        .unwrap_or(0);
    let modified = fact("modify").and_then(parse_mlsd_modify);
    let display_name = match type_value.as_str() {
        "cdir" => ".",
        "pdir" => "..",
        _ => name,
    };
    Some(MediaItem {
        id: display_name.to_string(),
        name: display_name.to_string(),
        is_directory,
        size,
        modified_at: modified.map(|seconds| seconds.to_string()),
        media_type: None,
    })
}

/// mac `parseUnixLine`: `drwxr-xr-x 2 user group 4096 Apr 22 10:00 name`.
/// At least 9 whitespace-separated fields, the mode starts with -/d/l, the
/// 5th field is the size, fields 6-8 are the date, the rest (spaces kept) is
/// the name.
fn parse_unix_line(line: &str) -> Option<MediaItem> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() < 9 || parts[0].len() < 10 {
        return None;
    }
    let mode = parts[0];
    if !(mode.starts_with('-') || mode.starts_with('d') || mode.starts_with('l')) {
        return None;
    }
    let size: i64 = parts[4].parse().ok()?;
    if size < 0 {
        return None;
    }
    let modified = parse_unix_list_date(parts[5], parts[6], parts[7]);
    let name = parts[8..].join(" ");
    // "link -> target": keep the link name only (mac keeps the whole tail;
    // VLC strips the arrow — the display name keeps spaces, matching mac).
    if name.is_empty() || name.contains('/') || name.contains('\0') {
        return None;
    }
    Some(MediaItem {
        id: name.clone(),
        name,
        is_directory: mode.starts_with('d'),
        size,
        modified_at: modified.map(|seconds| seconds.to_string()),
        media_type: None,
    })
}

/// Blocking FTP control channel: line replies with the RFC 959 continuation
/// form (`123-...` lines until `123 ...`), a 1 MiB reply cap and the 10s read
/// timeout from the task spec.
struct FtpSession {
    control: TcpStream,
    buffer: Vec<u8>,
    eof: bool,
    host: String,
}

impl FtpSession {
    fn connect(host: &str, port: u16) -> Result<Self, FtpError> {
        let control = TcpStream::connect((host, port))
            .map_err(|error| FtpError::Connection(error.to_string()))?;
        control
            .set_read_timeout(Some(READ_TIMEOUT))
            .map_err(|error| FtpError::Connection(error.to_string()))?;
        Ok(Self {
            control,
            buffer: Vec::new(),
            eof: false,
            host: host.to_string(),
        })
    }

    /// mac `login`: greeting 220 → USER (230 done / 331 → PASS must be 230).
    fn login(&mut self, username: &str, password: &str) -> Result<(), FtpError> {
        if !self.command(None)?.starts_with("220") {
            return Err(FtpError::Connection("unexpected greeting".into()));
        }
        let user = self.command(Some(&format!("USER {username}")))?;
        if user.starts_with("230") {
            return Ok(());
        }
        if !user.starts_with("331") {
            return Err(FtpError::Login);
        }
        if !self.command(Some(&format!("PASS {password}")))?.starts_with("230") {
            return Err(FtpError::Login);
        }
        Ok(())
    }

    /// Sends `text` (when given) and reads one reply. Command injection is
    /// rejected the same way as the mac client (no CR/LF/NUL).
    fn command(&mut self, text: Option<&str>) -> Result<String, FtpError> {
        if let Some(text) = text {
            if text.bytes().any(|byte| byte == 13 || byte == 10 || byte == 0) {
                return Err(FtpError::BadUrl);
            }
            let line = format!("{text}\r\n");
            self.control
                .write_all(line.as_bytes())
                .map_err(|error| FtpError::Connection(error.to_string()))?;
        }
        self.read_reply()
    }

    fn read_reply(&mut self) -> Result<String, FtpError> {
        let first = self.read_line()?;
        let bytes = first.as_bytes();
        if bytes.len() < 3 || !bytes[..3].iter().all(u8::is_ascii_digit) {
            return Err(FtpError::Connection("invalid reply".into()));
        }
        if bytes.len() < 4 || bytes[3] != b'-' {
            return Ok(first);
        }
        let code = first[..3].to_string();
        let mut lines = vec![first];
        let mut count = lines[0].len();
        loop {
            let line = self.read_line()?;
            count += line.len();
            if count > REPLY_LIMIT {
                return Err(FtpError::ResponseTooLarge);
            }
            let done = line == code || line.starts_with(&format!("{code} "));
            lines.push(line);
            if done {
                return Ok(lines.join("\n"));
            }
        }
    }

    fn read_line(&mut self) -> Result<String, FtpError> {
        loop {
            if let Some(position) = find_crlf(&self.buffer) {
                let line: Vec<u8> = self.buffer.drain(..position + 2).collect();
                let line = &line[..line.len() - 2];
                return String::from_utf8(line.to_vec())
                    .map_err(|_| FtpError::Connection("invalid reply encoding".into()));
            }
            if self.eof {
                return Err(FtpError::Connection("connection closed during reply".into()));
            }
            let mut chunk = [0u8; 64 * 1024];
            let read = self
                .control
                .read(&mut chunk)
                .map_err(map_read_error)?;
            if read == 0 {
                self.eof = true;
                continue;
            }
            self.buffer.extend_from_slice(&chunk[..read]);
            if self.buffer.len() > REPLY_LIMIT {
                return Err(FtpError::ResponseTooLarge);
            }
        }
    }

    /// mac `listDirectory`: TYPE I → for MLSD then LIST: PASV → connect data
    /// channel → send the verb → 1xx → read data → 226/250. An MLSD 5xx
    /// falls through to LIST; a 2xx reply to the verb means an
    /// already-completed empty transfer.
    fn list_directory(&mut self, path: &str) -> Result<String, FtpError> {
        if !self.command(Some("TYPE I"))?.starts_with('2') {
            return Err(FtpError::Listing);
        }
        for verb in ["MLSD", "LIST"] {
            let pasv = self.command(Some("PASV"))?;
            if !pasv.starts_with("227") {
                return Err(FtpError::Connection("server does not support PASV".into()));
            }
            let port = parse_pasv(&pasv)
                .ok_or_else(|| FtpError::Connection("cannot parse passive mode response".into()))?;
            // PASV addresses are hints (often a private/0.0.0.0 address
            // behind NAT); connect back to the control host, not the
            // advertised IP (mac rule, VLC does the same in practice).
            let mut data = TcpStream::connect((self.host.as_str(), port))
                .map_err(|error| FtpError::Connection(error.to_string()))?;
            data.set_read_timeout(Some(READ_TIMEOUT))
                .map_err(|error| FtpError::Connection(error.to_string()))?;
            let reply = self.command(Some(&format!("{verb} {path}")))?;
            if verb == "MLSD" && reply.starts_with('5') {
                continue; // server rejects MLSD: fall back to LIST
            }
            if reply.starts_with('2') {
                return Ok(String::new()); // already-completed empty transfer
            }
            if !reply.starts_with('1') {
                return Err(FtpError::Listing);
            }
            let listing = read_all_data(&mut data)?;
            let completion = self.command(None)?;
            if !(completion.starts_with("226") || completion.starts_with("250")) {
                return Err(FtpError::Listing);
            }
            return Ok(listing);
        }
        Err(FtpError::Listing)
    }
}

fn map_read_error(error: std::io::Error) -> FtpError {
    match error.kind() {
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => FtpError::Timeout,
        _ => FtpError::Connection(error.to_string()),
    }
}

fn find_crlf(buffer: &[u8]) -> Option<usize> {
    buffer.windows(2).position(|window| window == b"\r\n")
}

fn read_all_data(data: &mut TcpStream) -> Result<String, FtpError> {
    let mut payload: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 256 * 1024];
    loop {
        let read = data.read(&mut chunk).map_err(map_read_error)?;
        if read == 0 {
            return String::from_utf8(payload)
                .map_err(|_| FtpError::Listing);
        }
        if payload.len() + read > DATA_LIMIT {
            return Err(FtpError::ResponseTooLarge);
        }
        payload.extend_from_slice(&chunk[..read]);
    }
}

/// mac `parsePASV` (VLC ftp_StartStream): the last "(h1,h2,h3,h4,p1,p2)"
/// group, all six fields 0-255, port = p1*256+p2, port 0 rejected.
fn parse_pasv(reply: &str) -> Option<u16> {
    let open = reply.rfind('(')?;
    let close = reply.rfind(')')?;
    if open >= close {
        return None;
    }
    let fields: Vec<&str> = reply[open + 1..close].split(',').collect();
    if fields.len() != 6 {
        return None;
    }
    let numbers: Vec<u16> = fields
        .iter()
        .map(|field| field.trim().parse::<u16>().ok())
        .collect::<Option<Vec<u16>>>()?;
    if !numbers.iter().all(|value| *value <= 255) {
        return None;
    }
    let port = numbers[4] as u16 * 256 + numbers[5] as u16;
    if port == 0 {
        None
    } else {
        Some(port)
    }
}
