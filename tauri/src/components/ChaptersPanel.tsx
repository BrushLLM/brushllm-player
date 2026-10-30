// Chapter list modeled on IINA's SidebarChaptersPane: title + start time,
// current chapter highlighted, click to seek. Shares the playlist sidebar's
// container styles (.pl-sidebar family).

import type { Chapter } from "../player-state";
import { useI18n } from "../i18n";

export interface ChaptersPanelProps {
  chapters: Chapter[];
  currentChapter: number | null;
  onSelect: (index: number) => void;
  /** Inside the shared Sidebar: skip the .pl-sidebar shell (it provides the
   *  container and the tab strip) and render only the list. */
  embedded?: boolean;
}

function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const total = Math.floor(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  if (hours > 0) return `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
  return `${minutes}:${String(secs).padStart(2, "0")}`;
}

export default function ChaptersPanel({ chapters, currentChapter, onSelect, embedded = false }: ChaptersPanelProps) {
  const { t } = useI18n();
  const body = (
    <>
      {!embedded && (
        <div className="pl-header">
          <span className="pl-title">{t("panel.chapters")}</span>
          <span className="pl-count">{chapters.length}</span>
        </div>
      )}

      <div className="pl-list" role="list">
        {chapters.length === 0 ? (
          <div className="pl-empty">{t("panel.chapters.none")}</div>
        ) : (
          chapters.map((chapter, index) => (
            <button
              key={`${index}-${chapter.time}`}
              type="button"
              role="listitem"
              className={`pl-row-main pl-chapter-row ${currentChapter === index ? "current" : ""}`}
              onClick={() => onSelect(index)}
              title={chapter.title}
            >
              <span className="pl-row-title">{chapter.title}</span>
              <span className="pl-chapter-time">{formatTime(chapter.time)}</span>
            </button>
          ))
        )}
      </div>
    </>
  );

  return embedded ? body : <aside className="pl-sidebar" aria-label={t("panel.chapters")}>{body}</aside>;
}
