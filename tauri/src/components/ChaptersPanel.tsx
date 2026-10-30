// Chapter list modeled on IINA's SidebarChaptersPane: title + start time,
// current chapter highlighted, click to seek. Shares the playlist sidebar's
// container styles (.pl-sidebar family).

import type { Chapter } from "../player-state";

export interface ChaptersPanelProps {
  chapters: Chapter[];
  currentChapter: number | null;
  onSelect: (index: number) => void;
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

export default function ChaptersPanel({ chapters, currentChapter, onSelect }: ChaptersPanelProps) {
  return (
    <aside className="pl-sidebar" aria-label="Chapters">
      <div className="pl-header">
        <span className="pl-title">Chapters</span>
        <span className="pl-count">{chapters.length}</span>
      </div>

      <div className="pl-list" role="list">
        {chapters.length === 0 ? (
          <div className="pl-empty">No chapters</div>
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
    </aside>
  );
}
