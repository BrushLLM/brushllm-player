import type { Chapter } from "../player-state";
import { formatClock } from "../library-state";
import { useI18n } from "../i18n";

export interface ChaptersPanelProps {
  chapters: Chapter[];
  currentChapter: number | null;
  onSelect: (index: number) => void;
  showTitle?: boolean;
}

export default function ChaptersPanel({ chapters, currentChapter, onSelect, showTitle = true }: ChaptersPanelProps) {
  const { t } = useI18n();
  return (
    <>
      {showTitle && <h2 className="sidebar-section-title">{t("panel.chapters")}</h2>}
      <div className="pl-list" role="list">
        {chapters.length === 0 ? (
          <div className="pl-empty">{t("panel.chapters.none")}</div>
        ) : (
          chapters.map((chapter, index) => (
            <button
              key={`${index}-${chapter.time}`}
              type="button"
              className={`pl-row-main pl-chapter-row ${currentChapter === index ? "current" : ""}`}
              onClick={() => onSelect(index)}
              title={chapter.title}
              aria-current={currentChapter === index ? "true" : undefined}
            >
              <span className="pl-row-title">{chapter.title}</span>
              <span className="pl-chapter-time">{formatClock(chapter.time)}</span>
            </button>
          ))
        )}
      </div>
    </>
  );

}
