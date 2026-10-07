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
}

export const initialState: PlayerState = {
  paused: true, position: 0, duration: 0, idle: true, mediaTitle: "", fileName: "",
  volume: 100, muted: false, speed: 1, playlistCount: 0, playlistPos: -1,
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
