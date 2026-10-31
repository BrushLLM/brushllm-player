// Media-server domain types and pure functions, ported from the mac
// MediaServer.swift (MediaServerKind / MediaItem / MediaSortMode) and the
// AddServerForm URL composer in NetworkPanel.swift. The Rust backend
// (src-tauri/src/servers) is the source of truth for the wire format; the
// types below mirror its camelCase serde output. No React, no Tauri imports:
// everything here is unit-testable (tests/player-state.test.mjs).

/** mac MediaServerKind — the five server kinds the backend supports. */
export type ServerKind = "webdav" | "smb" | "ftp" | "emby" | "jellyfin";

/** mac MediaServerSource (servers_list/servers_add wire format). */
export interface ServerSource {
  id: string;
  kind: ServerKind;
  name: string;
  baseUrl: string;
  username: string;
  password: string;
}

/** mac MediaItem (servers_browse wire format). `modifiedAt` is a unix-seconds
 *  string (or ISO8601 text); `mediaType` is set for Emby/Jellyfin only. */
export interface MediaItem {
  id: string;
  name: string;
  isDirectory: boolean;
  size: number;
  modifiedAt: string | null;
  mediaType: "audio" | "video" | null;
}

/** mac MediaSortMode: name / modified / size. */
export type MediaSortMode = "name" | "modified" | "size";

/** mac MediaTypes.playableExtensions — the extension whitelist used to
 *  decide playability for filesystem-like kinds (webdav/smb/ftp). */
export const PLAYABLE_EXTENSIONS: ReadonlySet<string> = new Set([
  // Video
  "mkv", "mp4", "m4v", "avi", "mov", "webm", "flv", "wmv", "mpg", "mpeg",
  "ts", "m2ts", "mts", "vob", "3gp", "ogv", "rmvb", "iso", "m3u8",
  // Audio
  "mp3", "flac", "wav", "aac", "ogg", "opus", "m4a", "wma", "ape", "wv", "aiff", "alac",
]);

/** The extension of a display name: the segment after the last dot, when the
 *  dot is not the first character and is not inside a leading dotfile stem
 *  (mac NSString.pathExtension: ".hidden" has no extension). */
export function nameExtension(name: string): string {
  const base = name.slice(Math.max(name.lastIndexOf("/"), name.lastIndexOf("\\")) + 1);
  const dot = base.lastIndexOf(".");
  if (dot <= 0 || dot === base.length - 1) return "";
  return base.slice(dot + 1).toLowerCase();
}

/** mac MediaItem.isPlayable: directories never play; Emby/Jellyfin need a
 *  media type; filesystem kinds use the extension whitelist. */
export function isPlayable(item: MediaItem, kind: ServerKind): boolean {
  if (item.isDirectory) return false;
  if (kind === "emby" || kind === "jellyfin") return item.mediaType !== null;
  return PLAYABLE_EXTENSIONS.has(nameExtension(item.name));
}

/** Parses a MediaItem.modifiedAt string into a unix-seconds number, or null.
 *  The backend sends unix-seconds strings; ISO8601 text (Emby DateModified)
 *  is accepted as well. Non-finite/garbage values read as unknown. */
export function parseModifiedAt(value: string | null): number | null {
  if (typeof value !== "string" || value.trim() === "") return null;
  const text = value.trim();
  if (/^-?\d+$/.test(text)) {
    const seconds = Number(text);
    return Number.isFinite(seconds) ? seconds : null;
  }
  const parsed = Date.parse(text);
  return Number.isFinite(parsed) ? Math.floor(parsed / 1000) : null;
}

/** Case-insensitive name comparison with a case-sensitive tiebreak, matching
 *  localizedCaseInsensitiveCompare + compare on the mac (a/A sort together;
 *  "a" < "A" when the insensitive pass ties). */
function compareNames(left: string, right: string): number {
  const lower = left.toLowerCase().localeCompare(right.toLowerCase());
  if (lower !== 0) return lower;
  if (left === right) return 0;
  return left < right ? -1 : 1;
}

/** Date comparison: known dates order before unknown ones regardless of
 *  direction (mac compareDates: unknown is always last, never falling back
 *  to a name comparison). */
function compareDates(left: number | null, right: number | null, ascending: boolean): number {
  if (left !== null && right !== null) {
    if (left === right) return 0;
    return directional(left < right ? -1 : 1, ascending);
  }
  if (left !== null && right === null) return -1;
  if (left === null && right !== null) return 1;
  return 0;
}

function directional(result: number, ascending: boolean): number {
  return ascending ? result : -result;
}

/** mac MediaSortMode.compare, as a comparator for Array.prototype.sort:
 *  - name: directories first (regardless of direction), then names.
 *  - modified: dates mixed (folders and files together), unknown last,
 *    ties fall back to the name (always ascending).
 *  - size: directories sink to the bottom (regardless of direction) and
 *    order among themselves by date; files compare by size.
 *  The final tiebreak is name (ascending) then id, so the sort is total. */
export function compareMediaItems(
  left: MediaItem,
  right: MediaItem,
  mode: MediaSortMode,
  ascending: boolean,
): number {
  switch (mode) {
    case "name": {
      if (left.isDirectory !== right.isDirectory) return left.isDirectory ? -1 : 1;
      const name = directional(compareNames(left.name, right.name), ascending);
      if (name !== 0) return name;
      break;
    }
    case "modified": {
      const date = compareDates(
        parseModifiedAt(left.modifiedAt), parseModifiedAt(right.modifiedAt), ascending,
      );
      if (date !== 0) return date;
      break;
    }
    case "size": {
      if (left.isDirectory !== right.isDirectory) return left.isDirectory ? 1 : -1;
      if (left.isDirectory) {
        const date = compareDates(
          parseModifiedAt(left.modifiedAt), parseModifiedAt(right.modifiedAt), ascending,
        );
        if (date !== 0) return date;
      } else if (left.size !== right.size) {
        return directional(left.size < right.size ? -1 : 1, ascending);
      }
      break;
    }
  }
  // Shared fallback: ascending name, then exact name, then id.
  const name = compareNames(left.name, right.name);
  if (name !== 0) return name;
  if (left.id < right.id) return -1;
  if (left.id > right.id) return 1;
  return 0;
}

/** mac MediaSortMode.apply: returns a new sorted array. */
export function sortMediaItems(items: MediaItem[], mode: MediaSortMode, ascending: boolean): MediaItem[] {
  return [...items].sort((left, right) => compareMediaItems(left, right, mode, ascending));
}

/** The structured add/edit form fields (mac AddServerForm state). */
export interface ServerFormFields {
  kind: ServerKind;
  name: string;
  scheme: "https" | "http";
  host: string;
  port: string;
  path: string;
  username: string;
  password: string;
}

export const EMPTY_SERVER_FORM: ServerFormFields = {
  kind: "webdav", name: "", scheme: "https", host: "", port: "", path: "",
  username: "", password: "",
};

/** mac AddServerForm.composedBaseURL: the connection string built from the
 *  structured fields. webdav/emby/jellyfin compose scheme://host[:port]
 *  (webdav appends the path); smb composes smb://host/share (path = share
 *  name); ftp composes ftp://host[:port][path]. */
export function composeBaseUrl(fields: ServerFormFields): string {
  const host = fields.host.trim();
  const port = fields.port.trim();
  let path = fields.path.trim();
  if (path !== "" && !path.startsWith("/")) path = `/${path}`;
  switch (fields.kind) {
    case "webdav": {
      let base = `${fields.scheme}://${host}`;
      if (port !== "") base += `:${port}`;
      if (path !== "") base += path;
      return base;
    }
    case "smb": {
      const share = path === "" ? "" : path.startsWith("/") ? path : `/${path}`;
      return `smb://${host}${share}`;
    }
    case "ftp": {
      let base = `ftp://${host}`;
      if (port !== "") base += `:${port}`;
      if (path !== "") base += path;
      return base;
    }
    case "emby":
    case "jellyfin": {
      let base = `${fields.scheme}://${host}`;
      if (port !== "") base += `:${port}`;
      return base;
    }
  }
}

/** mac AddServerForm.requiredFieldsFilled: a host is always required; SMB
 *  additionally needs the share name. */
export function requiredFieldsFilled(fields: ServerFormFields): boolean {
  if (fields.host.trim() === "") return false;
  if (fields.kind === "smb" && fields.path.trim() === "") return false;
  return true;
}

/** The display name a saved source gets: the typed title, or the host when
 *  the title was left empty (mac add(): name.isEmpty ? host : newName). */
export function serverDisplayName(fields: ServerFormFields): string {
  const title = fields.name.trim();
  return title !== "" ? title : fields.host.trim();
}

/** Decomposes a saved source's baseUrl back into the structured form fields
 *  so the edit form opens exactly as the server was added (mac
 *  prefillIfEditing). Unparseable URLs fall back to the raw string as host. */
export function formFieldsFromSource(source: ServerSource): ServerFormFields {
  const fields: ServerFormFields = {
    ...EMPTY_SERVER_FORM,
    kind: source.kind,
    name: source.name,
    username: source.username,
    password: source.password,
  };
  let url: URL | null = null;
  try {
    url = new URL(source.baseUrl);
  } catch {
    url = null;
  }
  if (url === null || url.host === "") {
    fields.host = source.baseUrl;
    return fields;
  }
  fields.scheme = url.protocol === "http:" ? "http" : "https";
  fields.host = url.hostname;
  fields.port = url.port !== "" ? url.port : "";
  if (source.kind === "smb") {
    // The path field is the share name; strip the leading slash.
    fields.path = url.pathname === "/" ? "" : url.pathname.replace(/^\//, "");
  } else {
    fields.path = url.pathname === "/" ? "" : url.pathname;
  }
  return fields;
}

/** scheme://host[:port] of a saved source for the card subtitle (mac
 *  ServersTab.hostLabel); falls back to the raw baseUrl. */
export function hostLabel(source: ServerSource): string {
  try {
    const url = new URL(source.baseUrl);
    if (url.host !== "") return url.port !== "" ? `${url.hostname}:${url.port}` : url.hostname;
  } catch {
    // Not a parseable absolute URL — show the raw string.
  }
  return source.baseUrl;
}

/** Human file size for browser rows (mac ByteCountFormatter .file style:
 *  binary units, one fraction digit under 1000). Zero/unknown sizes render
 *  as an empty string (the row hides the size column). */
export function formatItemSize(size: number): string {
  if (!Number.isFinite(size) || size <= 0) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = size;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const digits = unit === 0 || value >= 1000 ? 0 : value >= 100 ? 0 : 1;
  return `${value.toFixed(digits)} ${units[unit]}`;
}

/** Maps a Rust ServerError ({ code, message }) to a localized, user-facing
 * message. Known codes get their own strings (servers.error.<code>); the
 * raw backend message is never shown to users — it stays in the console. */
export function serverErrorMessage(
  error: unknown,
  t: (key: string) => string,
): string {
  if (typeof error === "object" && error !== null && "code" in error) {
    const code = (error as { code: unknown }).code;
    if (typeof code === "string" && code !== "") {
      const key = `servers.error.${code}`;
      const localized = t(key);
      // t() falls back to the key name when a translation is missing.
      if (localized !== key) return localized;
      console.warn("[servers] unlocalized error code:", code,
        (error as { message?: unknown }).message);
      return t("servers.error.generic");
    }
  }
  console.warn("[servers] unrecognized error shape:", error);
  return t("servers.error.generic");
}
