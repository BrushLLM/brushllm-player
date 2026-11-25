import type { ReactNode } from "react";
import { useI18n } from "../i18n";
import brandIcon from "../../../Sources/BrushLLMPlayer/Resources/Base.lproj/PlayerIcon.svg";
import PlayerIcon, { type PlayerIconName } from "./PlayerIcon";

export type SidebarSection = "sources" | "playlist" | "history" | "bookmarks" | "chapters";

const destinations = [
  { id: "sources", label: "player.sources", icon: "folder" },
  { id: "playlist", label: "panel.playlist.title", icon: "playlist" },
  { id: "history", label: "panel.history", icon: "history" },
  { id: "bookmarks", label: "panel.bookmarks", icon: "bookmark" },
] as const;

interface SidebarProps {
  compact: boolean;
  section: SidebarSection;
  onSelect: (section: SidebarSection) => void;
  onFiles: () => void;
  onStream: () => void;
  onServers: () => void;
  onSettings: () => void;
  onAbout: () => void;
  children: ReactNode;
}

function SidebarButton({ icon, title, pressed, action }: {
  icon: PlayerIconName;
  title: string;
  pressed?: boolean;
  action: () => void;
}) {
  return (
    <button type="button" className="sidebar-button" aria-pressed={pressed} aria-label={title} title={title} onClick={action}>
      <PlayerIcon name={icon} />
      <span className="sidebar-label">{title}</span>
    </button>
  );
}

export default function Sidebar({
  compact, section, onSelect, onFiles, onStream, onServers, onSettings, onAbout, children,
}: SidebarProps) {
  const { t } = useI18n();
  const current = section === "chapters" ? "playlist" : section;
  const label = section === "chapters" ? "panel.chapters" : destinations.find(({ id }) => id === current)?.label;

  return (
    <aside className="player-sidebar" data-compact={compact}>
      <div className="sidebar-brand">
        <img src={brandIcon} width="32" height="32" alt="" />
        <span>BrushLLM Player</span>
      </div>
      <nav className="sidebar-navigation" aria-label={t("player.workspace")}>
        {destinations.map(({ id, label, icon }) => (
          <SidebarButton key={id} icon={icon} title={t(label)} pressed={current === id}
            action={() => onSelect(id)} />
        ))}
      </nav>
      <section id="sidebar-content" className="sidebar-content" hidden={compact} aria-label={label ? t(label) : undefined}>
        {!compact && (section === "sources" ? (
          <div className="sidebar-sources">
            <SidebarButton title={t("player.open-files")} icon="folder" action={onFiles} />
            <SidebarButton title={t("network.tab.url")} icon="link" action={onStream} />
            <SidebarButton title={t("network.tab.servers")} icon="servers" action={onServers} />
          </div>
        ) : children)}
      </section>
      <div className="sidebar-footer">
        <SidebarButton title={t("player.settings")} icon="settings" action={onSettings} />
        <button className="tool-btn" type="button" aria-label={t("about.menu")} title={t("about.menu")} onClick={onAbout}>
          <PlayerIcon name="info" />
        </button>
      </div>
    </aside>
  );
}
