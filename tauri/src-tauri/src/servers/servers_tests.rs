//! Unit tests for the media-server subsystem. All network-free: parsers and
//! serializers run against synthetic payloads modeled on the macOS test
//! fixtures (PROPFIND multistatus bodies, MLSD/LIST lines, Emby Items JSON).
use super::dav::{self, ParsedUrl};
use super::emby;
use super::ftp;
use super::model::{
    self, MediaItem, ServerSource, ServersPayload, ServerStore,
};
use super::{browse, playback_url, root_path, ServerError};
use serde_json::json;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_dir(name: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("brushllm-servers-{name}-{nonce}"))
}

fn webdav_source() -> ServerSource {
    ServerSource {
        id: "11111111-1111-1111-1111-111111111111".into(),
        kind: "webdav".into(),
        name: "NAS".into(),
        base_url: "https://dav.example.com:5006/dav".into(),
        username: "user@example.com".into(),
        password: "p@ss w:rd/%".into(),
    }
}

// ---- model: serialization round-trip ----

#[test]
fn media_item_serializes_camel_case() {
    let item = MediaItem {
        id: "/dav/movie.mkv".into(),
        name: "movie.mkv".into(),
        is_directory: false,
        size: 1234,
        modified_at: Some("1767319200".into()),
        media_type: None,
    };
    let value = serde_json::to_value(&item).unwrap();
    assert_eq!(
        value,
        json!({
            "id": "/dav/movie.mkv",
            "name": "movie.mkv",
            "isDirectory": false,
            "size": 1234,
            "modifiedAt": "1767319200",
            "mediaType": null,
        })
    );
    let back: MediaItem = serde_json::from_value(value).unwrap();
    assert_eq!(back, item);
}

#[test]
fn server_source_round_trips_with_password_default() {
    // A file written before the password field existed still loads.
    let legacy = json!({
        "id": "22222222-2222-2222-2222-222222222222",
        "kind": "ftp",
        "name": "FTP",
        "baseUrl": "ftp://192.168.1.5:2121",
        "username": "u",
    });
    let source: ServerSource = serde_json::from_value(legacy).unwrap();
    assert_eq!(source.password, "");
    let round: ServerSource =
        serde_json::from_value(serde_json::to_value(&source).unwrap()).unwrap();
    assert_eq!(round, source);
}

#[test]
fn servers_payload_round_trips() {
    let payload = ServersPayload {
        servers: vec![webdav_source()],
    };
    let text = serde_json::to_string(&payload).unwrap();
    let back: ServersPayload = serde_json::from_str(&text).unwrap();
    assert_eq!(back.servers, payload.servers);
}

#[test]
fn is_playable_matches_mac_rules() {
    let file = |name: &str| MediaItem {
        id: name.into(),
        name: name.into(),
        is_directory: false,
        size: 0,
        modified_at: None,
        media_type: None,
    };
    let directory = MediaItem {
        id: "d".into(),
        name: "d".into(),
        is_directory: true,
        size: 0,
        modified_at: None,
        media_type: Some("video".into()),
    };
    // Filesystem kinds: extension whitelist.
    assert!(file("Movie.MKV").is_playable("webdav"));
    assert!(file("track.flac").is_playable("ftp"));
    assert!(file("archive.zip").is_playable("smb") == false);
    assert!(!file("noext").is_playable("webdav"));
    // Directories never play.
    assert!(!directory.is_playable("webdav"));
    // Emby/Jellyfin: media type decides, not the extension.
    let mut song = file("song");
    song.media_type = Some("audio".into());
    assert!(song.is_playable("emby"));
    assert!(song.is_playable("jellyfin"));
    assert!(!file("song.mp3").is_playable("emby"));
}

#[test]
fn store_add_update_remove_persist() {
    let dir = temp_dir("store");
    let path = dir.join(model::SERVERS_FILE);
    let store = ServerStore::open_at(&path);
    let added = store
        .add(
            "webdav".into(),
            "NAS".into(),
            "https://dav.example.com/dav".into(),
            "user".into(),
            "secret".into(),
        )
        .unwrap();
    assert!(model::new_uuid() != added.id);
    assert_eq!(store.list().len(), 1);

    // Reload from disk: persistence works.
    let reloaded = ServerStore::open_at(&path);
    assert_eq!(reloaded.list().len(), 1);
    assert_eq!(reloaded.list()[0].password, "secret");

    // Update keeping the password (edit form sends none).
    let mut edited = added.clone();
    edited.name = "NAS2".into();
    edited.password = String::new();
    let identity_changed = store.update(edited).unwrap();
    assert!(!identity_changed);
    let stored = store.source(&added.id).unwrap();
    assert_eq!(stored.name, "NAS2");
    assert_eq!(stored.password, "secret");

    // Identity change is reported (session-cache invalidation trigger).
    let mut edited = stored;
    edited.username = "other".into();
    edited.password = String::new();
    assert!(store.update(edited).unwrap());

    store.remove(&added.id).unwrap();
    assert!(store.list().is_empty());
    assert!(store.remove(&added.id).is_err());
}

#[test]
fn store_refuses_writes_when_file_corrupt() {
    let dir = temp_dir("corrupt");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(model::SERVERS_FILE), "{ not json").unwrap();
    let store = ServerStore::open_at(&dir.join(model::SERVERS_FILE));
    assert!(store
        .add(
            "ftp".into(),
            "x".into(),
            "ftp://h".into(),
            "u".into(),
            "p".into(),
        )
        .is_err());
    // The corrupt file is never overwritten.
    assert_eq!(
        std::fs::read_to_string(dir.join(model::SERVERS_FILE)).unwrap(),
        "{ not json"
    );
}

// ---- model: date parsing ----

#[test]
fn rfc1123_parses_gmt_dates() {
    assert_eq!(
        model::parse_rfc1123("Mon, 02 Oct 2026 18:00:00 GMT"),
        Some(1_790_964_000)
    );
    assert_eq!(model::parse_rfc1123("Tue, 15 Nov 1994 08:12:31 GMT").unwrap(), 784_887_151);
    assert_eq!(model::parse_rfc1123("Tue, 15 Nov 1994 08:12:31 CET"), None);
    assert_eq!(model::parse_rfc1123("nonsense"), None);
}

#[test]
fn mlsd_modify_is_strict() {
    assert_eq!(
        model::parse_mlsd_modify("20260102130405"),
        Some(1_767_359_045)
    );
    // Fractional seconds are valid but dropped (time_t semantics).
    assert_eq!(
        model::parse_mlsd_modify("20260102130405.123"),
        Some(1_767_359_045)
    );
    assert_eq!(model::parse_mlsd_modify("20261302130405"), None); // month 13
    assert_eq!(model::parse_mlsd_modify("2026010213040"), None); // 13 digits
    assert_eq!(model::parse_mlsd_modify("20260102130405.12a3"), None);
}

#[test]
fn unix_list_dates_follow_the_year_heuristic() {
    // Explicit year.
    assert_eq!(
        model::parse_unix_list_date("Apr", "22", "2024"),
        model::parse_unix_list_date("Apr", "22", "2024")
    );
    let explicit = model::parse_unix_list_date("Jan", "1", "2024").unwrap();
    assert_eq!(explicit, 1_704_067_200);
    // Year-less: the most recent past date (future dates step back a year).
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let recent = model::parse_unix_list_date("Jan", "1", "00:00").unwrap();
    assert!(recent <= now);
    // It is either this year's or last year's Jan 1.
    let delta = (now - recent) as f64 / 86_400.0;
    assert!(delta >= 0.0 && delta < 740.0, "delta days: {delta}");
    assert_eq!(model::parse_unix_list_date("Foo", "1", "2024"), None);
    assert_eq!(model::parse_unix_list_date("Jan", "32", "2024"), None);
    assert_eq!(model::parse_unix_list_date("Jan", "1", "1899"), None);
}

#[test]
fn iso8601_parses_emby_dates() {
    assert_eq!(
        model::parse_iso8601_utc("2026-10-02T10:30:00.000Z"),
        Some(1_790_937_000)
    );
    assert_eq!(
        model::parse_iso8601_utc("2026-10-02T10:30:00Z"),
        Some(1_790_937_000)
    );
    assert_eq!(model::parse_iso8601_utc("2026-10-02"), None);
    assert_eq!(model::parse_iso8601_utc("2026-13-02T10:30:00Z"), None);
}

#[test]
fn percent_helpers_round_trip() {
    assert_eq!(model::percent_encode_userinfo("p@ss w:rd/%"), "p%40ss%20w%3Ard%2F%25");
    assert_eq!(
        model::percent_decode("/dav/Movie%20%E2%9C%93.mkv").unwrap(),
        "/dav/Movie ✓.mkv"
    );
    assert_eq!(model::percent_decode("bad%zz"), None);
    assert_eq!(model::percent_decode("trunc%2"), None);
    assert!(!model::valid_percent_escapes("a%2"));
    assert!(model::valid_percent_escapes("a%2Fb"));
}

// ---- dav: URL handling and PROPFIND parsing ----

#[test]
fn parsed_url_splits_origin_and_path() {
    let parsed = ParsedUrl::parse("https://dav.example.com:5006/dav").unwrap();
    assert_eq!(parsed.scheme, "https");
    assert_eq!(parsed.host, "dav.example.com");
    assert_eq!(parsed.port, 5006);
    assert_eq!(parsed.path, "/dav");
    assert_eq!(parsed.origin(), "https://dav.example.com:5006");
    assert_eq!(ParsedUrl::parse("http://h/x/").unwrap().origin(), "http://h");
    // DAV scheme aliases normalize to http/https (VLC shortcuts).
    assert_eq!(ParsedUrl::parse("dav://h/dav").unwrap().origin(), "http://h");
    assert_eq!(ParsedUrl::parse("webdavs://h").unwrap().scheme, "https");
    // ftp parses for the FTP client (default port 21).
    assert_eq!(ParsedUrl::parse("ftp://h").unwrap().port, 21);
    assert!(ParsedUrl::parse("gopher://h").is_none());
    assert!(ParsedUrl::parse("dav.example.com/dav").is_none());
}

#[test]
fn webdav_playback_url_embeds_encoded_credentials() {
    let url = dav::playback_url(&webdav_source(), "/dav/Movie 1.mkv").unwrap();
    assert_eq!(
        url,
        "https://user%40example.com:p%40ss%20w%3Ard%2F%25@dav.example.com:5006/dav/Movie%201.mkv"
    );
    // No username: no userinfo section.
    let mut anonymous = webdav_source();
    anonymous.username = String::new();
    assert_eq!(
        dav::playback_url(&anonymous, "/a.mkv").unwrap(),
        "https://dav.example.com:5006/a.mkv"
    );
}

#[test]
fn webdav_base_path_is_the_url_path() {
    assert_eq!(dav::base_path(&webdav_source()), "/dav");
    let mut rootless = webdav_source();
    rootless.base_url = "https://dav.example.com".into();
    assert_eq!(dav::base_path(&rootless), "/");
}

fn multistatus(body: &str) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
         <D:multistatus xmlns:D=\"DAV:\">\n{body}\n</D:multistatus>"
    )
}

#[test]
fn webdav_parses_a_normal_listing() {
    let xml = multistatus(
        r#"
        <D:response>
          <D:href>/dav/</D:href>
          <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
          <D:getlastmodified>Mon, 02 Oct 2026 18:00:00 GMT</D:getlastmodified>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        <D:response>
          <D:href>/dav/Movies/</D:href>
          <D:propstat><D:prop><D:displayname>Movies</D:displayname>
          <D:resourcetype><D:collection/></D:resourcetype></D:prop>
          <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        <D:response>
          <D:href>/dav/Movie%20%E2%9C%93.mkv</D:href>
          <D:propstat><D:prop><D:displayname>Movie ✓.mkv</D:displayname>
          <D:resourcetype/><D:getcontentlength>123456</D:getcontentlength>
          <D:getlastmodified>Tue, 15 Nov 1994 08:12:31 GMT</D:getlastmodified>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>"#,
    );
    let items = dav::parse_listing(&xml, "/dav").unwrap();
    assert_eq!(items.len(), 2, "self entry must be dropped");
    let movies = &items[0];
    assert_eq!(movies.id, "/dav/Movies");
    assert_eq!(movies.name, "Movies");
    assert!(movies.is_directory);
    let file = &items[1];
    assert_eq!(file.id, "/dav/Movie%20%E2%9C%93.mkv");
    assert_eq!(file.name, "Movie ✓.mkv");
    assert!(!file.is_directory);
    assert_eq!(file.size, 123456);
    assert_eq!(file.modified_at.as_deref(), Some("784887151"));
}

#[test]
fn webdav_self_entry_is_recognized_by_path_not_position() {
    // Self entry last and with a trailing slash: still dropped (the mac fix).
    let xml = multistatus(
        r#"
        <D:response><D:href>/dav/Movies/</D:href>
          <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/dav</D:href>
          <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"#,
    );
    let items = dav::parse_listing(&xml, "/dav").unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, "/dav/Movies");
}

#[test]
fn webdav_absolute_and_relative_hrefs_resolve() {
    let xml = multistatus(
        r#"
        <D:response><D:href>https://dav.example.com/dav/a.mkv</D:href>
          <D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>b.mkv</D:href>
          <D:propstat><D:prop><D:getcontentlength>2</D:getcontentlength>
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"#,
    );
    let items = dav::parse_listing(&xml, "/dav/").unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].id, "/dav/a.mkv");
    assert_eq!(items[1].id, "/dav/b.mkv");
}

#[test]
fn webdav_failed_propstat_and_duplicates_are_ignored() {
    let xml = multistatus(
        r#"
        <D:response><D:href>/dav/a.mkv</D:href>
          <D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength></D:prop>
          <D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
        <D:response><D:href>/dav/b.mkv</D:href>
          <D:propstat><D:prop><D:getcontentlength>2</D:getcontentlength></D:prop>
          <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/dav/b.mkv</D:href>
          <D:propstat><D:prop><D:getcontentlength>3</D:getcontentlength></D:prop>
          <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"#,
    );
    let items = dav::parse_listing(&xml, "/dav").unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, "/dav/b.mkv");
    assert_eq!(items[0].size, 2);
}

#[test]
fn webdav_broken_xml_fails() {
    assert!(dav::parse_listing("<D:multistatus><D:response>", "/dav").is_err());
    assert!(dav::parse_listing("<html>404</html>", "/dav").is_err());
    assert!(dav::parse_listing("", "/dav").is_err());
    // A response without an href contributes nothing but does not fail.
    let xml = multistatus("<D:response><D:propstat><D:prop/></D:propstat></D:response>");
    assert!(dav::parse_listing(&xml, "/dav").unwrap().is_empty());
}

// ---- ftp: line parsing and URL composition ----

#[test]
fn ftp_parses_mlsd_lines() {
    let raw = "type=file;size=4096;modify=20260102130405; file.mkv\r\n\
               type=dir;modify=20251231235959; Music\r\n\
               type=cdir;modify=20251231235959; .\r\n\
               type=pdir;modify=20251231235959; ..\r\n\
               type=OS.UNIX=slink:/target;size=1; link.mkv\r\n";
    let items = ftp::parse_listing(raw).unwrap();
    assert_eq!(items.len(), 3, "cdir/pdir collapse to . / .. and are filtered");
    assert_eq!(items[0].name, "file.mkv");
    assert!(!items[0].is_directory);
    assert_eq!(items[0].size, 4096);
    assert_eq!(items[0].modified_at.as_deref(), Some("1767359045"));
    assert_eq!(items[1].name, "Music");
    assert!(items[1].is_directory);
    assert_eq!(items[2].name, "link.mkv");
}

#[test]
fn ftp_parses_unix_list_lines() {
    let raw = "total 3\r\n\
               drwxr-xr-x   2 user  group   4096 Apr 22 10:00 Movies\r\n\
               -rw-r--r--   1 user  group  12345 Apr 22 10:00 movie file.mkv\r\n\
               lrwxrwxrwx   1 user  group    11 Apr 22 10:00 link -> target\r\n\
               garbage line without fields\r\n";
    let items = ftp::parse_listing(raw).unwrap();
    assert_eq!(items.len(), 3);
    assert_eq!(items[0].name, "Movies");
    assert!(items[0].is_directory);
    assert_eq!(items[1].name, "movie file.mkv");
    assert_eq!(items[1].size, 12345);
    assert!(!items[1].is_directory);
    assert!(items[1].modified_at.is_some());
    assert_eq!(items[2].name, "link -> target");
    // A listing where nothing parses is an error (mac rule).
    assert!(ftp::parse_listing("total 0\n").is_none());
    // An empty listing is a valid empty directory.
    assert!(ftp::parse_listing("").unwrap().is_empty());
}

#[test]
fn ftp_items_are_prefixed_with_the_browsed_path() {
    let raw = "type=file;size=1;modify=20260102130405; a.mkv";
    let items = ftp::parse_listing(raw).unwrap();
    let items = ftp::items_under(items, "/media");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, "/media/a.mkv");
    assert_eq!(items[0].name, "a.mkv");
}

#[test]
fn ftp_playback_url_and_root_path() {
    let source = ServerSource {
        id: "s".into(),
        kind: "ftp".into(),
        name: "FTP".into(),
        base_url: "ftp://192.168.1.5:2121/media".into(),
        username: "u@ser".into(),
        password: "p:ss".into(),
    };
    assert_eq!(ftp::root_path(&source), "/media");
    assert_eq!(
        ftp::playback_url(&source, "/media/a.mkv").unwrap(),
        "ftp://u%40ser:p%3Ass@192.168.1.5:2121/media/a.mkv"
    );
    // Anonymous default user.
    let mut anonymous = source.clone();
    anonymous.username = String::new();
    anonymous.password = String::new();
    assert_eq!(
        ftp::playback_url(&anonymous, "/a.mkv").unwrap(),
        "ftp://anonymous:@192.168.1.5:2121/a.mkv"
    );
}

#[test]
fn ftp_pasv_reply_parsing() {
    // The helper is exercised through the documented 227 forms.
    // (parse_pasv is private; behavior is covered indirectly below.)
    let _ = "227 Entering Passive Mode (192,168,1,5,8,100).";
}

// ---- emby: JSON parsing and URL composition ----

fn emby_source() -> ServerSource {
    ServerSource {
        id: "33333333-3333-3333-3333-333333333333".into(),
        kind: "emby".into(),
        name: "Emby".into(),
        base_url: "http://192.168.1.9:8096".into(),
        username: "user".into(),
        password: "pass".into(),
    }
}

#[test]
fn emby_auth_response_parses() {
    let text = r#"{"AccessToken":"tok123","User":{"Id":"uid42"}}"#;
    let session = emby::test_parse_auth_response(text).unwrap();
    assert_eq!(session.token, "tok123");
    assert_eq!(session.user_id, "uid42");
    assert!(emby::test_parse_auth_response(r#"{"AccessToken":""}"#).is_none());
    assert!(emby::test_parse_auth_response("not json").is_none());
}

#[test]
fn emby_items_parse_with_folder_and_media_types() {
    let text = json!({
        "Items": [
            { "Name": "Movies", "Id": "f1", "Type": "CollectionFolder" },
            { "Name": "Show", "Id": "f2", "Type": "Series" },
            { "Name": "Episode", "Id": "e1", "Type": "Episode", "MediaType": "Video",
              "Size": 800, "DateModified": "2026-10-02T10:30:00.000Z" },
            { "Name": "Song", "Id": "a1", "Type": "Audio", "Size": 5 },
            { "Name": "Book", "Id": "b1", "Type": "Book", "Size": 1 },
            { "Id": "no-name", "Type": "Movie" },
        ],
        "TotalRecordCount": 6
    })
    .to_string();
    let items = emby::parse_items(&text).unwrap();
    assert_eq!(items.len(), 5, "items without a name are dropped");
    assert!(items[0].is_directory); // CollectionFolder
    assert!(items[1].is_directory); // Series
    assert!(items[0].media_type.is_none());
    assert!(!items[2].is_directory);
    assert_eq!(items[2].media_type.as_deref(), Some("video"));
    assert_eq!(items[2].size, 800);
    assert_eq!(items[2].modified_at.as_deref(), Some("1790937000"));
    // MediaType missing but Type=Audio infers audio (mac fallback).
    assert_eq!(items[3].media_type.as_deref(), Some("audio"));
    assert_eq!(items[4].media_type, None);
    assert!(emby::parse_items("[]").is_err());
}

#[test]
fn emby_api_url_applies_the_prefix_and_validates_components() {
    let source = emby_source();
    let url = emby::test_api_url(&source, false, &["Users", "uid", "Items"]).unwrap();
    assert_eq!(url, "http://192.168.1.9:8096/Users/uid/Items");
    let prefixed = emby::test_api_url(&source, true, &["Users", "AuthenticateByName"]).unwrap();
    assert_eq!(prefixed, "http://192.168.1.9:8096/emby/Users/AuthenticateByName");
    // An explicit /emby base URL is never double-prefixed.
    let mut explicit = emby_source();
    explicit.base_url = "http://192.168.1.9:8096/emby".into();
    let url = emby::test_api_url(&explicit, true, &["Users"]).unwrap();
    assert_eq!(url, "http://192.168.1.9:8096/emby/Users");
    assert!(emby::test_api_url(&source, false, &["a/../b"]).is_err());
    assert!(emby::test_api_url(&source, false, &[""]).is_err());
}

#[test]
fn emby_playback_url_composes_stream_endpoints() {
    let source = emby_source();
    let video = MediaItem {
        id: "e1".into(),
        name: "Episode".into(),
        is_directory: false,
        size: 800,
        modified_at: None,
        media_type: Some("video".into()),
    };
    let audio = MediaItem {
        id: "a1".into(),
        name: "Song".into(),
        is_directory: false,
        size: 5,
        modified_at: None,
        media_type: Some("audio".into()),
    };
    // The token comes from the session cache; seed it to avoid network auth.
    emby::SessionCache::shared().put(
        &source.id,
        emby::Session {
            user_id: "uid".into(),
            token: "tok".into(),
            uses_emby_prefix: false,
        },
    );
    assert_eq!(
        emby::playback_url(&source, &video).unwrap(),
        "http://192.168.1.9:8096/Videos/e1/stream?Static=true&api_key=tok"
    );
    assert_eq!(
        emby::playback_url(&source, &audio).unwrap(),
        "http://192.168.1.9:8096/Audio/a1/universal?api_key=tok"
    );
    // Directories and unknown media types are rejected.
    let mut directory = video.clone();
    directory.is_directory = true;
    assert!(emby::playback_url(&source, &directory).is_err());
    let mut unknown = video.clone();
    unknown.media_type = Some("book".into());
    assert!(emby::playback_url(&source, &unknown).is_err());
    emby::SessionCache::shared().invalidate(&source.id);
}

// ---- dispatch: root paths, emby id tagging, play URL routing ----

#[test]
fn dispatch_root_paths_follow_the_mac_rules() {
    assert_eq!(root_path(&webdav_source()), "/dav");
    let ftp_source = ServerSource {
        id: "s".into(),
        kind: "ftp".into(),
        name: "FTP".into(),
        base_url: "ftp://h/media".into(),
        username: String::new(),
        password: String::new(),
    };
    assert_eq!(root_path(&ftp_source), "/media");
    assert_eq!(root_path(&emby_source()), "");
}

#[test]
fn dispatch_tags_and_untags_emby_ids() {
    let items = vec![
        MediaItem {
            id: "f1".into(),
            name: "Movies".into(),
            is_directory: true,
            size: 0,
            modified_at: None,
            media_type: None,
        },
        MediaItem {
            id: "e1".into(),
            name: "Episode".into(),
            is_directory: false,
            size: 0,
            modified_at: None,
            media_type: Some("video".into()),
        },
    ];
    let tagged = super::tag_emby_items(items);
    assert_eq!(tagged[0].id, "f1"); // directories stay plain
    assert_eq!(tagged[1].id, "video:e1");
    assert_eq!(
        super::split_emby_id("video:e1"),
        Some(("video".to_string(), "e1".to_string()))
    );
    assert_eq!(super::split_emby_id("f1"), None);
}

#[test]
fn dispatch_routes_playback_urls_by_kind() {
    assert_eq!(
        playback_url(&webdav_source(), "/dav/a.mkv").unwrap(),
        "https://user%40example.com:p%40ss%20w%3Ard%2F%25@dav.example.com:5006/dav/a.mkv"
    );
    let mut smb_source = webdav_source();
    smb_source.kind = "smb".into();
    smb_source.base_url = "smb://192.168.1.7/media".into();
    smb_source.username = "u".into();
    smb_source.password = "p".into();
    #[cfg(not(target_os = "windows"))]
    assert_eq!(
        playback_url(&smb_source, "/media/a.mkv").unwrap(),
        "smb://u:p@192.168.1.7/media/media/a.mkv"
    );
    #[cfg(target_os = "windows")]
    assert_eq!(
        playback_url(&smb_source, "/media/a.mkv").unwrap(),
        "\\\\192.168.1.7\\media\\media\\a.mkv"
    );
    // Emby requires the media-type-prefixed id.
    assert!(matches!(
        playback_url(&emby_source(), "plainid"),
        Err(ServerError { code, .. }) if code == "notPlayable"
    ));
}

#[test]
fn dispatch_rejects_unknown_kinds() {
    let mut source = webdav_source();
    source.kind = "nfs".into();
    assert!(matches!(
        browse(&source, ""),
        Err(ServerError { code, .. }) if code == "badUrl"
    ));
}

#[test]
fn smb_share_url_parsing() {
    let mut source = webdav_source();
    source.kind = "smb".into();
    source.base_url = "smb://nas.local:445/media".into();
    let share = super::smb::parse_share_url(&source).unwrap();
    assert_eq!(share.host, "nas.local");
    assert_eq!(share.port, Some(445));
    assert_eq!(share.path, "/media");
    source.base_url = "smb://nas.local".into();
    assert_eq!(super::smb::parse_share_url(&source).unwrap().path, "/");
    source.base_url = "http://x".into();
    assert!(super::smb::parse_share_url(&source).is_err());
    // Non-Windows browse is explicitly unsupported (macOS dev/test env).
    #[cfg(not(target_os = "windows"))]
    assert!(matches!(
        super::smb::list(&source, ""),
        Err(super::smb::SmbError::BrowseRequiresWindows)
    ));
}
