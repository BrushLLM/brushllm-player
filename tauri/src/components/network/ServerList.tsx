// Server list state of the servers tab, ported from the mac ServersTab list
// view: one glass card per saved server (kind icon, name, kind badge, host
// subtitle, Connect / edit / delete), a dashed "Add Server" card at the
// bottom, and an empty state with a direct add button when no servers exist.

import { useI18n } from "../../i18n";
import type { ServerKind, ServerSource } from "../../server-state";
import { hostLabel } from "../../server-state";
import { KindIcon } from "./KindIcon";

export interface ServerListProps {
  servers: ServerSource[];
  onConnect: (server: ServerSource) => void;
  onEdit: (server: ServerSource) => void;
  onRemove: (server: ServerSource) => void;
  onAdd: () => void;
}

export default function ServerList({ servers, onConnect, onEdit, onRemove, onAdd }: ServerListProps) {
  const { t } = useI18n();

  if (servers.length === 0) {
    return (
      <div className="net-empty">
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <rect x="3" y="4" width="18" height="6" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <rect x="3" y="14" width="18" height="6" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <circle cx="7" cy="7" r="0.8" fill="currentColor" />
          <circle cx="7" cy="17" r="0.8" fill="currentColor" />
        </svg>
        <div className="net-empty-message">{t("media.empty")}</div>
        <button type="button" className="net-empty-action" onClick={onAdd}>
          {t("webdav.add")}
        </button>
      </div>
    );
  }

  return (
    <div className="net-server-list" role="list">
      {servers.map((server) => (
        <div key={server.id} className="net-server-card" role="listitem">
          <span className="net-server-icon"><KindIcon kind={server.kind} /></span>
          <span className="net-server-text">
            <span className="net-server-name-line">
              <span className="net-server-name">{server.name}</span>
              <span className="net-kind-badge">{server.kind.toUpperCase()}</span>
            </span>
            <span className="net-server-host">{hostLabel(server)}</span>
          </span>
          <button type="button" className="net-server-connect" onClick={() => onConnect(server)}>
            {t("webdav.connect-server")}
          </button>
          <button
            type="button"
            className="net-server-round"
            onClick={() => onEdit(server)}
            title={t("webdav.edit")}
            aria-label={`${t("webdav.edit")} ${server.name}`}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M4 20 L4 16 L15 5 L19 9 L8 20 Z" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
              <path d="M13 7 L17 11" stroke="currentColor" strokeWidth="1.6" />
            </svg>
          </button>
          <button
            type="button"
            className="net-server-round"
            onClick={() => onRemove(server)}
            title={t("panel.delete")}
            aria-label={`${t("panel.delete")} ${server.name}`}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <circle cx="12" cy="12" r="8.6" fill="none" stroke="currentColor" strokeWidth="1.6" />
              <line x1="9" y1="9" x2="15" y2="15" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
              <line x1="15" y1="9" x2="9" y2="15" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
            </svg>
          </button>
        </div>
      ))}
      <button type="button" className="net-add-card" onClick={onAdd}>
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <circle cx="12" cy="12" r="8.6" fill="none" stroke="currentColor" strokeWidth="1.6" />
          <path d="M12 8.5 V15.5 M8.5 12 H15.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
        {t("webdav.add")}
      </button>
    </div>
  );
}
