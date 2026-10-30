// Bookmarks list ported from the mac BookmarksPanel: each row shows a bookmark
// icon, the title, and the timestamp; clicking a row seeks to the bookmark.
// The footer offers "add at current position" and a destructive clear. Data is
// fetched by the parent (invoke("bookmark_list")) and passed in — this
// component only renders. Rendered inside the shared Sidebar (embedded), so
// no .pl-sidebar shell of its own.

import type { Bookmark } from "../library-state";
import { formatBookmarkTime } from "../library-state";
import { useI18n } from "../i18n";

export interface BookmarksPanelProps {
  bookmarks: Bookmark[];
  onAdd: () => void;
  onSelect: (time: number) => void;
  onRemove: (id: number) => void;
  onClear: () => void;
}

export default function BookmarksPanel({ bookmarks, onAdd, onSelect, onRemove, onClear }: BookmarksPanelProps) {
  const { t } = useI18n();
  return (
    <>
      <div className="pl-list" role="list">
        {bookmarks.length === 0 ? (
          <div className="pl-empty">{t("panel.bookmarks.empty")}</div>
        ) : (
          bookmarks.map((bookmark) => (
            <div key={bookmark.id} role="listitem" className="pl-row">
              <button
                type="button"
                className="pl-row-main pl-lib-row"
                onClick={() => onSelect(bookmark.time)}
                title={bookmark.title}
              >
                <svg className="pl-lib-icon pl-bookmark-icon" viewBox="0 0 24 24" aria-hidden="true">
                  <path d="M7 3.5 H17 V20.5 L12 16.5 L7 20.5 Z" fill="none" stroke="currentColor"
                    strokeWidth="1.8" strokeLinejoin="round" />
                </svg>
                <span className="pl-lib-text">
                  <span className="pl-lib-title">{bookmark.title}</span>
                  <span className="pl-lib-subtitle">{formatBookmarkTime(bookmark.time)}</span>
                </span>
              </button>
              <button
                type="button"
                className="pl-row-delete"
                onClick={() => onRemove(bookmark.id)}
                aria-label={`${t("panel.delete")} ${bookmark.title}`}
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
          className="pl-footer-btn"
          onClick={onAdd}
          title={t("menu.bookmark-add")}
          aria-label={t("menu.bookmark-add")}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <line x1="12" y1="5" x2="12" y2="19" stroke="currentColor" strokeWidth="2"
              strokeLinecap="round" />
            <line x1="5" y1="12" x2="19" y2="12" stroke="currentColor" strokeWidth="2"
              strokeLinecap="round" />
          </svg>
        </button>
        <span className="pl-footer-spacer" aria-hidden="true" />
        <span className="pl-footer-gap" aria-hidden="true" />
        <button
          type="button"
          className="pl-footer-btn pl-clear"
          onClick={onClear}
          disabled={bookmarks.length === 0}
          title={t("panel.bookmarks.clear")}
          aria-label={t("panel.bookmarks.clear")}
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
