// Library data model (history + bookmarks) for the Phase 2 port of the mac
// HistoryBookmarksPanel. Pure types and formatters only — no Tauri imports —
// so the node test runner can compile this file directly like player-state.ts.

/** One playback history entry (mac PlaybackStore.HistoryEntry: path is the key). */
export interface HistoryEntry {
  path: string;
  title: string;
  duration: number;
  position: number;
  /** Unix seconds of the last play. */
  lastPlayedAt: number;
  playCount: number;
}

/** One bookmark for the current file (mac PlaybackStore.Bookmark). */
export interface Bookmark {
  id: number;
  path: string;
  /** Bookmark position in seconds. */
  time: number;
  title: string;
  /** Unix seconds of creation. */
  createdAt: number;
}

// mm:ss / h:mm:ss clock format shared with ChaptersPanel.formatTime.
export function formatClock(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const total = Math.floor(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  if (hours > 0) return `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
  return `${minutes}:${String(secs).padStart(2, "0")}`;
}

// Local calendar date as YYYY-MM-DD (never the UTC-shifted ISO string).
function formatDate(unixSeconds: number): string {
  const date = new Date(unixSeconds * 1000);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

/**
 * Abbreviated relative time like IINA/mac RelativeDateTimeFormatter:
 * "just now" (<60s), "5m ago" (<60m), "3h ago" (<24h), "2d ago" (<7d),
 * then YYYY-MM-DD. Clock skew (future timestamps) reads as "just now".
 */
export function formatRelativeTime(unixSeconds: number, now: number): string {
  if (!Number.isFinite(unixSeconds) || !Number.isFinite(now)) return "";
  const elapsed = Math.floor(now - unixSeconds);
  if (elapsed < 60) return "just now";
  if (elapsed < 3600) return `${Math.floor(elapsed / 60)}m ago`;
  if (elapsed < 86400) return `${Math.floor(elapsed / 3600)}h ago`;
  if (elapsed < 604800) return `${Math.floor(elapsed / 86400)}d ago`;
  return formatDate(unixSeconds);
}

/** History row subtitle: "12:34 / 1:23:45 · 5m ago". */
export function formatHistorySubtitle(entry: HistoryEntry, now: number): string {
  const position = formatClock(entry.position);
  const duration = entry.duration > 0 ? formatClock(entry.duration) : "--:--";
  return `${position} / ${duration} · ${formatRelativeTime(entry.lastPlayedAt, now)}`;
}

export function formatBookmarkTime(seconds: number): string {
  return formatClock(seconds);
}
