// Right-side playlist sidebar modeled on IINA's SidebarPlaylistPane: current
// entry highlighted, per-row delete, loop (off/file/playlist) + shuffle +
// clear in the footer. All actions flow through props; the parent owns the
// mpv commands (playlist-play-index / playlist-remove / playlist-clear /
// playlist-shuffle / set_property loop-file,loop-playlist).

import type { PlaylistEntry } from "../player-state";
import { useI18n } from "../i18n";

export type LoopMode = "off" | "file" | "playlist";

export interface PlaylistPanelProps {
  visible: boolean;
  entries: PlaylistEntry[];
  onPlay: (index: number) => void;
  onRemove: (index: number) => void;
  onClear: () => void;
  onShuffle: () => void;
  loopFile: boolean;
  loopPlaylist: boolean;
  onLoop: (mode: LoopMode) => void;
  /** Inside the shared Sidebar: skip the .pl-sidebar shell (it provides the
   *  container and the tab strip) and render only the list + footer. */
  embedded?: boolean;
}

function displayName(entry: PlaylistEntry): string {
  if (entry.title) return entry.title;
  // filename is a path or URL; show the last segment.
  const name = entry.filename;
  const slash = Math.max(name.lastIndexOf("/"), name.lastIndexOf("\\"));
  return slash >= 0 ? name.slice(slash + 1) : name;
}

export default function PlaylistPanel({
  visible, entries, onPlay, onRemove, onClear, onShuffle,
  loopFile, loopPlaylist, onLoop, embedded = false,
}: PlaylistPanelProps) {
  const { t } = useI18n();
  if (!visible) return null;

  const loopMode: LoopMode = loopPlaylist ? "playlist" : loopFile ? "file" : "off";
  const nextLoop: LoopMode =
    loopMode === "off" ? "file" : loopMode === "file" ? "playlist" : "off";

  const body = (
    <>
      {!embedded && (
        <div className="pl-header">
          <span className="pl-title">{t("panel.playlist.title")}</span>
          <span className="pl-count">{entries.length}</span>
        </div>
      )}

      <div className="pl-list" role="list">
        {entries.length === 0 ? (
          <div className="pl-empty">{t("panel.playlist.empty")}</div>
        ) : (
          entries.map((entry, index) => (
            <div
              key={`${index}-${entry.filename}`}
              role="listitem"
              className={`pl-row ${entry.current ? "current" : ""}`}
            >
              <button
                type="button"
                className="pl-row-main"
                onClick={() => onPlay(index)}
                title={displayName(entry)}
              >
                {entry.playing && (
                  <svg className="pl-playing-icon" viewBox="0 0 24 24" aria-hidden="true">
                    <path d="M4 9 L4 15 M7.5 6 L7.5 18 M11 9 L11 15 M14.5 4 L14.5 20"
                      stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />
                  </svg>
                )}
                <span className="pl-row-title">{displayName(entry)}</span>
              </button>
              <button
                type="button"
                className="pl-row-delete"
                onClick={() => onRemove(index)}
                aria-label={`${t("panel.delete")} ${displayName(entry)}`}
                title={t("panel.delete")}
              >
                <svg viewBox="0 0 24 24" aria-hidden="true">
                  <line x1="6" y1="6" x2="18" y2="18" />
                  <line x1="18" y1="6" x2="6" y2="18" />
                </svg>
              </button>
            </div>
          ))
        )}
      </div>

      <div className="pl-footer">
        <button
          type="button"
          className={`pl-footer-btn ${loopMode !== "off" ? "active" : ""}`}
          onClick={() => onLoop(nextLoop)}
          title={
            loopMode === "off" ? t("loop.off") : loopMode === "file" ? t("loop.file") : t("loop.playlist")
          }
          aria-label={t("menu.loop")}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            {loopMode === "file" && <text x="12" y="15" textAnchor="middle" fontSize="9"
              fill="currentColor" stroke="none">1</text>}
            <path d="M17 3 L21 6.5 L17 10" fill="none" stroke="currentColor" strokeWidth="2"
              strokeLinecap="round" strokeLinejoin="round" />
            <path d="M21 6.5 H8 a5 5 0 0 0 -5 5 v1" fill="none" stroke="currentColor"
              strokeWidth="2" strokeLinecap="round" />
            <path d="M7 21 L3 17.5 L7 14" fill="none" stroke="currentColor" strokeWidth="2"
              strokeLinecap="round" strokeLinejoin="round" />
            <path d="M3 17.5 H16 a5 5 0 0 0 5 -5 v-1" fill="none" stroke="currentColor"
              strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
        <button
          type="button"
          className="pl-footer-btn"
          onClick={onShuffle}
          title={t("panel.playlist.shuffle")}
          aria-label={t("panel.playlist.shuffle")}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M3 7 H7 L17 17 H21" fill="none" stroke="currentColor" strokeWidth="2"
              strokeLinecap="round" />
            <path d="M3 17 H7 L13 11" fill="none" stroke="currentColor" strokeWidth="2"
              strokeLinecap="round" />
            <path d="M15 7 H21" fill="none" stroke="currentColor" strokeWidth="2"
              strokeLinecap="round" />
            <path d="M18 4 L21 7 L18 10" fill="none" stroke="currentColor" strokeWidth="2"
              strokeLinecap="round" strokeLinejoin="round" />
            <path d="M18 14 L21 17 L18 20" fill="none" stroke="currentColor" strokeWidth="2"
              strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
        {/* Destructive clear gets extra separation from the neighbors. */}
        <span className="pl-footer-spacer" aria-hidden="true" />
        <button
          type="button"
          className="pl-footer-btn pl-clear"
          onClick={onClear}
          title={t("panel.playlist.clear")}
          aria-label={t("panel.playlist.clear")}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M4 7 H20" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
            <path d="M9 7 V5 H15 V7" fill="none" stroke="currentColor" strokeWidth="2"
              strokeLinecap="round" strokeLinejoin="round" />
            <path d="M6.5 7 L7.5 20 H16.5 L17.5 7" fill="none" stroke="currentColor"
              strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
      </div>
    </>
  );

  return embedded ? body : <aside className="pl-sidebar" aria-label={t("panel.playlist.title")}>{body}</aside>;
}
