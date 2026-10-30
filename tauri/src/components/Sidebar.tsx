// Unified right sidebar shell for the four library tabs
// (playlist/chapters/history/bookmarks). Owns the .pl-sidebar container, the
// tab strip (text capsule buttons, active tab on --accent-bright with dark
// text, like the mac PlaylistPanel tab pills) and a trailing close button.
// The content area renders children — the parent mounts the matching panel
// for the current tab. PlaylistPanel/ChaptersPanel accept embedded={true} to
// drop their own shell; HistoryPanel/BookmarksPanel are always embedded.

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
          >
            {t(labelKey)}
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
