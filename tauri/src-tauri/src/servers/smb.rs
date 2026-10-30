//! SMB client.
//!
//! Windows: the official mpv builds do not include libsmbclient, so browsing
//! goes through the native UNC filesystem (`std::fs::read_dir` accepts
//! `\\host\share\...` directly) with credentials established by a best-effort
//! `net use` call, and playback passes the UNC path to mpv. Non-Windows
//! platforms (macOS development builds ship libsmbclient via FFmpeg) get
//! `smb://user:pass@host/...` URLs instead, and browsing returns an error —
//! the browse path is only exercised on real Windows machines.
use super::model::{percent_encode_userinfo, MediaItem, ServerSource};

#[derive(Debug)]
pub enum SmbError {
    BadUrl,
    BadPath,
    BrowseRequiresWindows,
    /// Windows-only: read_dir/metadata failures.
    #[allow(dead_code)]
    Io(String),
}

impl std::fmt::Display for SmbError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SmbError::BadUrl => write!(formatter, "Invalid SMB share URL"),
            SmbError::BadPath => write!(formatter, "Invalid path inside the share"),
            SmbError::BrowseRequiresWindows => write!(formatter, "Browse requires Windows"),
            SmbError::Io(detail) => write!(formatter, "SMB operation failed: {detail}"),
        }
    }
}

/// The `smb://host[:port]/share/...` split used by both platform branches.
pub struct SmbUrl {
    pub host: String,
    pub port: Option<u16>,
    /// URL path starting with `/` (may be just `/`, meaning the host root).
    pub path: String,
}

pub fn parse_share_url(source: &ServerSource) -> Result<SmbUrl, SmbError> {
    let url = source.base_url.trim();
    let rest = url
        .strip_prefix("smb://")
        .ok_or(SmbError::BadUrl)?
        .split(['?', '#'])
        .next()
        .ok_or(SmbError::BadUrl)?;
    let (authority, path) = match rest.split_once('/') {
        Some((authority, path)) => (authority, format!("/{path}")),
        None => (rest, "/".to_string()),
    };
    let authority = authority.rsplit_once('@').map(|(_, host)| host).unwrap_or(authority);
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) if !port.is_empty() => (host, port.parse::<u16>().ok()),
        _ => (authority, None),
    };
    if host.is_empty() || host.contains(['[', ']', '/']) {
        return Err(SmbError::BadUrl);
    }
    Ok(SmbUrl {
        host: host.to_string(),
        port,
        path,
    })
}

/// mac `SMBClient.absolutePath` rule: no NUL, no `..` segments.
fn validate_relative(path: &str) -> Result<(), SmbError> {
    let relative = path.strip_prefix('/').unwrap_or(path);
    if relative.contains('\0') || relative.split('/').any(|segment| segment == "..") {
        return Err(SmbError::BadPath);
    }
    Ok(())
}

/// `\\host\share\path` form of the share URL path plus a browse path.
#[cfg(target_os = "windows")]
fn to_backslashes(path: &str) -> String {
    path.replace('/', "\\")
}

/// Browse-path normalization: the id prefix for children of `path`
/// ("/dir" → "/dir/", "" → "/").
#[cfg(target_os = "windows")]
fn prefix_for(path: &str) -> String {
    if path.ends_with('/') {
        path.to_string()
    } else {
        format!("{path}/")
    }
}

#[cfg(target_os = "windows")]
pub fn list(source: &ServerSource, path: &str) -> Result<Vec<MediaItem>, SmbError> {
    let share = parse_share_url(source)?;
    validate_relative(path)?;
    // Best-effort credential session for the share (or host root). The
    // password travels as a command-line argument — a documented
    // simplification; the Windows Credential Manager is the future fix.
    establish_credentials(source, &share);
    let unc_root = format!("\\\\{}{}", share.host, to_backslashes(&share.path));
    let full = format!("{}{}", unc_root, to_backslashes(path));
    let entries = std::fs::read_dir(&full).map_err(|error| SmbError::Io(error.to_string()))?;
    let prefix = prefix_for(path);
    let mut items = Vec::new();
    // mac list(): hidden dot-files are skipped.
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let metadata = entry
            .metadata()
            .map_err(|error| SmbError::Io(error.to_string()))?;
        let modified = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|duration| duration.as_secs().to_string());
        items.push(MediaItem {
            id: format!("{prefix}{name}"),
            name,
            is_directory: metadata.is_dir(),
            size: if metadata.is_dir() { 0 } else { metadata.len() as i64 },
            modified_at: modified,
            media_type: None,
        });
    }
    Ok(items)
}

#[cfg(target_os = "windows")]
fn establish_credentials(source: &ServerSource, share: &SmbUrl) {
    if source.username.is_empty() {
        return;
    }
    // Target the first path segment (the share) when present, else the host.
    let target = match share.path.trim_matches('/').split_once('/') {
        Some((first, _)) => format!("\\\\{}\\{}", share.host, first),
        None => format!("\\\\{}", share.host),
    };
    let status = std::process::Command::new("net")
        .arg("use")
        .arg(&target)
        .arg(format!("/user:{}", source.username))
        .arg(&source.password)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    // Failures are not fatal: an existing session (or guest access) may
    // already serve the share; read_dir reports the real outcome.
    if let Err(error) = status {
        log::warn!("net use failed to start for {target}: {error}");
    }
}

#[cfg(target_os = "windows")]
pub fn playback_path(source: &ServerSource, path: &str) -> Result<String, SmbError> {
    let share = parse_share_url(source)?;
    validate_relative(path)?;
    Ok(format!(
        "\\\\{}{}{}",
        share.host,
        to_backslashes(&share.path),
        to_backslashes(path)
    ))
}

/// Non-Windows (macOS development): browsing is not implemented — the mount
/// machinery from the mac app is not part of this port; real usage is the
/// Windows UNC path.
#[cfg(not(target_os = "windows"))]
pub fn list(_source: &ServerSource, _path: &str) -> Result<Vec<MediaItem>, SmbError> {
    Err(SmbError::BrowseRequiresWindows)
}

/// Non-Windows playback: `smb://user:pass@host[:port]/share/path` — the macOS
/// mpv build embeds libsmbclient through FFmpeg, so mpv opens it natively.
#[cfg(not(target_os = "windows"))]
pub fn playback_path(source: &ServerSource, path: &str) -> Result<String, SmbError> {
    let share = parse_share_url(source)?;
    validate_relative(path)?;
    let user = if source.username.is_empty() {
        "guest".to_string()
    } else {
        percent_encode_userinfo(&source.username)
    };
    let password = percent_encode_userinfo(&source.password);
    let port = share
        .port
        .map(|port| format!(":{port}"))
        .unwrap_or_default();
    Ok(format!(
        "smb://{user}:{password}@{}{}{}",
        share.host,
        port,
        join_share_path(&share.path, path)
    ))
}

#[cfg(not(target_os = "windows"))]
fn join_share_path(share_path: &str, path: &str) -> String {
    let mut full = share_path.trim_end_matches('/').to_string();
    let relative = path.trim_start_matches('/');
    if !relative.is_empty() {
        full.push('/');
        full.push_str(relative);
    }
    if full.is_empty() {
        "/".to_string()
    } else {
        full
    }
}
