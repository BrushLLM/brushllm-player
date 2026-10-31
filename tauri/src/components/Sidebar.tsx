// Unified right sidebar shell for the four library tabs
// (playlist/chapters/history/bookmarks). Owns the .pl-sidebar container, the
// tab strip and a trailing close button. Each tab has an icon + label; when
// the labels don't fit the 264px sidebar (long localizations like English
// "Bookmarks"), the CSS drops to icon-only (the web equivalent of the mac
// app's ViewThatFits fallback). The active tab uses the lemon accent with
// dark text, matching the mac PlaylistPanel tab pills.

import type { ReactNode } from "react";
import { useI18n } from "../i18n";

export type SidebarTab = "playlist" | "chapters" | "history" | "bookmarks";

export interface SidebarProps {
  open: boolean;
  tab: SidebarTab;
  onTabChange: (tab: SidebarTab) => void;
  onClose: () => void;
  children: ReactNode;
}

const TAB_ICONS: Record<SidebarTab, ReactNode> = {
  playlist: (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M4 6 H20 M4 12 H20 M4 18 H14" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
    </svg>
  ),
  chapters: (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <rect x="3" y="4" width="18" height="16" rx="2" fill="none" stroke="currentColor" strokeWidth="1.6" />
      <path d="M3 9 H21 M8 9 V20 M16 9 V20" stroke="currentColor" strokeWidth="1.6" />
    </svg>
  ),
  history: (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M3 12 A9 9 0 1 1 12 21 M12 7 V12 L16 15" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  ),
  bookmarks: (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M6 3 H18 V21 L12 16 L6 21 Z" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>
  ),
};

const TABS: { id: SidebarTab; labelKey: string }[] = [
  { id: "playlist", labelKey: "panel.playlist.title" },
  { id: "chapters", labelKey: "panel.chapters" },
  { id: "history", labelKey: "panel.history" },
  { id: "bookmarks", labelKey: "panel.bookmarks" },
];

export default function Sidebar({ open, tab, onTabChange, onClose, children }: SidebarProps) {
  const { t } = useI18n();
  if (!open) return null;

  return (
    <aside className="pl-sidebar" aria-label="Sidebar">
      <div className="pl-tabs" role="tablist" aria-label="Sidebar sections">
        {TABS.map(({ id, labelKey }) => (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={tab === id}
            className={`pl-tab ${tab === id ? "active" : ""}`}
            onClick={() => onTabChange(id)}
            title={t(labelKey)}
          >
            <span className="pl-tab-icon">{TAB_ICONS[id]}</span>
            <span className="pl-tab-label">{t(labelKey)}</span>
          </button>
        ))}
        <button
          type="button"
          className="pl-tab-close"
          onClick={onClose}
          aria-label={t("panel.cancel")}
          title={t("panel.cancel")}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <line x1="6" y1="6" x2="18" y2="18" />
            <line x1="18" y1="6" x2="6" y2="18" />
          </svg>
        </button>
      </div>

      <div className="pl-tab-content">{children}</div>
    </aside>
  );
}
