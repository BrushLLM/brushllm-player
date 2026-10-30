// Audio/subtitle track picker popup modeled on IINA's SidebarTrackSelector:
// an "Off" row, one row per track (title/lang, "Track N" fallback), the
// current selection marked. Selection goes through props; the parent issues
// set_property aid/sid (null → "no").

import { useEffect, useRef } from "react";
import type { Track } from "../player-state";
import { useI18n } from "../i18n";

export interface TrackMenuProps {
  kind: "audio" | "sub";
  tracks: Track[];
  currentId: number | null;
  onSelect: (id: number | null) => void;
  onClose: () => void;
}

function trackLabel(track: Track, index: number): string {
  const name = track.title || `Track ${index + 1}`;
  return track.lang ? `${name} (${track.lang})` : name;
}

export default function TrackMenu({ kind, tracks, currentId, onSelect, onClose }: TrackMenuProps) {
  const { t } = useI18n();
  const rootRef = useRef<HTMLDivElement>(null);

  const relevant = tracks.filter((track) => track.type === kind);

  // Escape / outside-click dismissal, same capture pattern as VideoSettingsMenu.
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onClose();
      }
    };
    const handlePointerDown = (event: MouseEvent | TouchEvent) => {
      const root = rootRef.current;
      if (root && event.target instanceof Node && !root.contains(event.target)) {
        onClose();
      }
    };
    document.addEventListener("keydown", handleKeyDown, true);
    document.addEventListener("mousedown", handlePointerDown, true);
    return () => {
      document.removeEventListener("keydown", handleKeyDown, true);
      document.removeEventListener("mousedown", handlePointerDown, true);
    };
  }, [onClose]);

  return (
    <div
      ref={rootRef}
      className="tm-menu"
      role="menu"
      aria-label={kind === "audio" ? t("panel.tracks.audio") : t("panel.tracks.subtitle")}
    >
      <button
        type="button"
        className={`tm-row ${currentId === null ? "selected" : ""}`}
        role="menuitemradio"
        aria-checked={currentId === null}
        onClick={() => { onSelect(null); onClose(); }}
      >
        <span className="tm-label">{t("panel.tracks.off")}</span>
        <span className="tm-check" aria-hidden="true">
          {currentId === null && (
            <svg viewBox="0 0 24 24"><path d="M5 12.5 L10 17.5 L19 7" fill="none"
              stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" /></svg>
          )}
        </span>
      </button>

      {relevant.map((track, index) => (
        <button
          key={`${track.type}-${track.id}`}
          type="button"
          className={`tm-row ${currentId === track.id ? "selected" : ""}`}
          role="menuitemradio"
          aria-checked={currentId === track.id}
          onClick={() => { onSelect(track.id); onClose(); }}
        >
          <span className="tm-label">{trackLabel(track, index)}</span>
          <span className="tm-check" aria-hidden="true">
            {currentId === track.id && (
              <svg viewBox="0 0 24 24"><path d="M5 12.5 L10 17.5 L19 7" fill="none"
                stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" /></svg>
            )}
          </span>
        </button>
      ))}
    </div>
  );
}
