// Playback history list ported from the mac HistoryPanel: each row shows a
// clock icon, the title, and a "position / duration · relative time" subtitle
// with a trailing delete button; clicking a row reopens the file. Data is
// fetched by the parent (invoke("history_list")) and passed in — this
// component only renders. Rendered inside the shared Sidebar (embedded), so
// no .pl-sidebar shell of its own.

import type { HistoryEntry } from "../library-state";
import { formatHistorySubtitle } from "../library-state";
import { useI18n } from "../i18n";

export interface HistoryPanelProps {
  entries: HistoryEntry[];
  onPlay: (path: string) => void;
  onRemove: (path: string) => void;
  onClear: () => void;
}

export default function HistoryPanel({ entries, onPlay, onRemove, onClear }: HistoryPanelProps) {
  const { t } = useI18n();
  const now = Math.floor(Date.now() / 1000);

  return (
    <>
      <div className="pl-list" role="list">
        {entries.length === 0 ? (
          <div className="pl-empty">{t("panel.history.empty")}</div>
        ) : (
          entries.map((entry) => (
            <div key={entry.path} role="listitem" className="pl-row">
              <button
                type="button"
                className="pl-row-main pl-lib-row"
                onClick={() => onPlay(entry.path)}
                title={entry.title}
              >
                <svg className="pl-lib-icon" viewBox="0 0 24 24" aria-hidden="true">
                  <path d="M4 12 A8 8 0 1 0 6.5 6.2" fill="none" stroke="currentColor"
                    strokeWidth="1.8" strokeLinecap="round" />
                  <path d="M4 4 V8 H8" fill="none" stroke="currentColor"
                    strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
                  <path d="M12 8 V12 L15 14" fill="none" stroke="currentColor"
                    strokeWidth="1.8" strokeLinecap="round" />
                </svg>
                <span className="pl-lib-text">
                  <span className="pl-lib-title">{entry.title}</span>
                  <span className="pl-lib-subtitle">
                    {formatHistorySubtitle(entry, now)}
                  </span>
                </span>
              </button>
              <button
                type="button"
                className="pl-row-delete"
                onClick={() => onRemove(entry.path)}
                aria-label={`${t("panel.delete")} ${entry.title}`}
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
        <span className="pl-footer-spacer" aria-hidden="true" />
        <span className="pl-footer-gap" aria-hidden="true" />
        <button
          type="button"
          className="pl-footer-btn pl-clear"
          onClick={onClear}
          disabled={entries.length === 0}
          title={t("panel.history.clear")}
          aria-label={t("panel.history.clear")}
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
}
