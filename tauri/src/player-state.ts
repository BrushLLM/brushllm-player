/** One mpv playlist entry (IINA MPVPlaylistItem: filename is the path, title optional). */
export interface PlaylistEntry {
  filename: string;
  title: string | null;
  current: boolean;
  playing: boolean;
}
/** One mpv chapter (IINA MPVChapter: title falls back to "Chapter N", time in seconds). */
export interface Chapter {
  title: string;
  time: number;
}
/** One mpv track (IINA MPVTrack: id, audio/video/sub type, optional title/lang, selected flag). */
export interface Track {
  id: number;
  type: "audio" | "video" | "sub";
  title: string | null;
  lang: string | null;
  selected: boolean;
}

export interface PlayerState {
  paused: boolean;
  position: number;
  duration: number;
  idle: boolean;
  mediaTitle: string;
  fileName: string;
  volume: number;
  muted: boolean;
  speed: number;
  playlistCount: number;
  playlistPos: number;
  playlist: PlaylistEntry[];
  chapters: Chapter[];
  currentChapter: number | null;
  tracks: Track[];
  audioTrackId: number | null;
  subtitleTrackId: number | null;
  abLoopA: number | null;
  abLoopB: number | null;
  loopFile: boolean;
  loopPlaylist: boolean;
  subDelay: number;
  audioDelay: number;
  hwdec: string;
  deinterlace: boolean;
  brightness: number;
  contrast: number;
  saturation: number;
  onTop: boolean;
  /** video-aspect-override; "-1" = container default (IINA aspectMode). */
  aspectMode: string;
  /** video-rotate in degrees (0/90/180/270). */
  rotation: number;
}

export const initialState: PlayerState = {
  paused: true, position: 0, duration: 0, idle: true, mediaTitle: "", fileName: "",
  volume: 100, muted: false, speed: 1, playlistCount: 0, playlistPos: -1,
  playlist: [], chapters: [], currentChapter: null, tracks: [],
  audioTrackId: null, subtitleTrackId: null,
  abLoopA: null, abLoopB: null, loopFile: false, loopPlaylist: false,
  subDelay: 0, audioDelay: 0, hwdec: "no", deinterlace: false,
  brightness: 0, contrast: 0, saturation: 0, onTop: false,
  aspectMode: "-1", rotation: 0,
};
export interface StateSnapshot {
  generation: number;
  mediaEpoch: number;
  revision: number;
  connected: boolean;
  ready: boolean;
  properties: Record<string, unknown>;
  endFile: { reason: string; file_error: string | null } | null;
  error: string | null;
}
export interface PlayerView {
  generation: number;
  mediaEpoch: number;
  revision: number;
  connected: boolean;
  ready: boolean;
  player: PlayerState;
  error: string | null;
}
export const initialView: PlayerView = {
  generation: 0, mediaEpoch: 0, revision: -1, connected: false, ready: false, player: initialState, error: null,
};

function finite(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}
function text(value: unknown): string { return typeof value === "string" ? value : ""; }

// mpv reports absent optional values as the string "no" (or JSON null).
function optionalText(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}
function optionalNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
// mpv sends "inf" when a loop is enabled and "no" when disabled.
function flagFromLoop(value: unknown): boolean {
  return value === "inf" || value === "yes" || value === true;
}
function records(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value.filter((item): item is Record<string, unknown> =>
    typeof item === "object" && item !== null) : [];
}

// IINA getPlaylist: filename is always present; title/current/playing are optional.
function parsePlaylist(value: unknown): PlaylistEntry[] {
  return records(value).map((entry) => ({
    filename: text(entry.filename),
    title: optionalText(entry.title),
    current: entry.current === true,
    playing: entry.playing === true,
  }));
}
// IINA MPVChapter: untitled chapters display as "Chapter N" (0-based index).
function parseChapters(value: unknown): Chapter[] {
  return records(value).map((entry, index) => ({
    title: text(entry.title) || `Chapter ${index}`,
    time: finite(entry.time, 0),
  }));
}
// IINA MPVTrack/TrackType: only audio/video/sub tracks are kept.
function parseTracks(value: unknown): Track[] {
  const tracks: Track[] = [];
  for (const entry of records(value)) {
    const type = entry.type;
    if (type !== "audio" && type !== "video" && type !== "sub") continue;
    const id = optionalNumber(entry.id);
    if (id === null) continue;
    tracks.push({
      id, type,
      title: optionalText(entry.title),
      lang: optionalText(entry.lang),
      selected: entry.selected === true,
    });
  }
  return tracks;
}

export function applySnapshot(previous: PlayerView, snapshot: StateSnapshot): PlayerView {
  if (snapshot.generation < previous.generation ||
      (snapshot.generation === previous.generation && snapshot.revision <= previous.revision)) return previous;
  const p = snapshot.connected ? snapshot.properties : {};
  return {
    generation: snapshot.generation, mediaEpoch: snapshot.mediaEpoch, revision: snapshot.revision,
    connected: snapshot.connected, ready: snapshot.connected && snapshot.ready,
    error: snapshot.error || (snapshot.endFile?.reason === "error"
      ? snapshot.endFile.file_error || "Media loading failed" : null),
    player: {
      paused: typeof p.pause === "boolean" ? p.pause : true,
      position: Math.max(0, finite(p["time-pos"], 0)),
      duration: Math.max(0, finite(p.duration, 0)),
      idle: typeof p["idle-active"] === "boolean" ? p["idle-active"] : true,
      mediaTitle: text(p["media-title"]), fileName: text(p.filename),
      volume: Math.min(130, Math.max(0, finite(p.volume, 100))),
      muted: p.mute === true, speed: finite(p.speed, 1),
      playlistCount: Math.max(0, finite(p["playlist-count"], 0)),
      playlistPos: finite(p["playlist-pos"], -1),
      playlist: parsePlaylist(p.playlist),
      chapters: parseChapters(p["chapter-list"]),
      currentChapter: optionalNumber(p.chapter),
      tracks: parseTracks(p["track-list"]),
      audioTrackId: optionalNumber(p.aid),
      subtitleTrackId: optionalNumber(p.sid),
      abLoopA: optionalNumber(p["ab-loop-a"]),
      abLoopB: optionalNumber(p["ab-loop-b"]),
      loopFile: flagFromLoop(p["loop-file"]),
      loopPlaylist: flagFromLoop(p["loop-playlist"]),
      subDelay: finite(p["sub-delay"], 0),
      audioDelay: finite(p["audio-delay"], 0),
      hwdec: text(p.hwdec) || "no",
      deinterlace: p.deinterlace === true,
      brightness: finite(p.brightness, 0),
      contrast: finite(p.contrast, 0),
      saturation: finite(p.saturation, 0),
      onTop: p.ontop === true,
      aspectMode: text(p["video-aspect-override"]) || "-1",
      rotation: finite(p["video-rotate"], 0),
    },
  };
}

export function sameMedia(a: Pick<PlayerView, "generation" | "mediaEpoch">,
                          b: Pick<PlayerView, "generation" | "mediaEpoch">): boolean {
  return a.generation === b.generation && a.mediaEpoch === b.mediaEpoch;
}

// Invokes can finish out of order even inside one connection. Only the latest
// user action may publish a rejection; media changes also invalidate old work.
export class CommandGate {
  private sequence = 0;
  begin(): number { return ++this.sequence; }
  invalidate(): void { ++this.sequence; }
  accepts(sequence: number): boolean { return sequence === this.sequence; }
}

export function commandError(error: unknown): { generation?: number; message: string } {
  if (typeof error === "object" && error !== null && "message" in error) {
    const value = error as { generation?: unknown; message: unknown };
    return {
      generation: typeof value.generation === "number" ? value.generation : undefined,
      message: typeof value.message === "string" ? value.message : String(value.message),
    };
  }
  return { message: error instanceof Error ? error.message : String(error) };
}

/// Mouse geometry always comes from the whole track, never its fill child.
export function trackFraction(clientX: number, left: number, width: number): number | null {
  if (![clientX, left, width].every(Number.isFinite) || width <= 0) return null;
  return Math.min(1, Math.max(0, (clientX - left) / width));
}
export function volumeAtClick(event: {
  clientX: number;
  currentTarget: { getBoundingClientRect(): { left: number; width: number } };
}): number | null {
  const rect = event.currentTarget.getBoundingClientRect();
  const fraction = trackFraction(event.clientX, rect.left, rect.width);
  return fraction === null ? null : Math.round(fraction * 130);
}
