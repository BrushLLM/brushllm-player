// Browser state of the servers tab, ported from the mac BrowserView: a top
// bar (back / kind icon / server name / current path / spinners / sort menu)
// above the item list. Rows enter directories or play files; right-clicking a
// folder offers "Add to Playlist" (the parent fetches the folder, filters
// playable items and enqueues them). Errors show a retry row; an empty folder
// shows the empty state; a pending browse shows a centered spinner.

import { useEffect, useRef, useState } from "react";

import { useI18n } from "../../i18n";
import type { MediaItem, MediaSortMode, ServerSource } from "../../server-state";
import { formatItemSize, isPlayable, sortMediaItems } from "../../server-state";
import { KindIcon } from "./KindIcon";

export interface BrowserViewProps {
  server: ServerSource;
  pathStack: string[];
  items: MediaItem[];
  isLoading: boolean;
  addingFolder: boolean;
  errorMessage: string | null;
  sortMode: MediaSortMode;
  sortAscending: boolean;
  onSortChange: (mode: MediaSortMode, ascending: boolean) => void;
  onBack: () => void;
  onReload: () => void;
  onEnterDirectory: (item: MediaItem) => void;
  onPlay: (item: MediaItem) => void;
  onAddFolderToPlaylist: (folder: MediaItem) => void;
}

function sortLabelKey(mode: MediaSortMode): string {
  switch (mode) {
    case "name": return "browser.sort.name";
    case "modified": return "browser.sort.modified";
    case "size": return "browser.sort.size";
  }
}

/** The current path label: the last path stack entry, or "/" at the root.
 *  Emby/Jellyfin ids are opaque strings, so the path column is hidden for
 *  those kinds (mac behavior). */
function currentPathLabel(pathStack: string[]): string {
  const last = pathStack[pathStack.length - 1] ?? "";
  return last === "" ? "/" : last;
}

export default function BrowserView({
  server, pathStack, items, isLoading, addingFolder, errorMessage,
  sortMode, sortAscending, onSortChange, onBack, onReload,
  onEnterDirectory, onPlay, onAddFolderToPlaylist,
}: BrowserViewProps) {
  const { t } = useI18n();
  const [sortMenuOpen, setSortMenuOpen] = useState(false);
  const sortMenuRef = useRef<HTMLDivElement>(null);

  // Close the sort menu on any outside click.
  useEffect(() => {
    if (!sortMenuOpen) return;
    const handlePointerDown = (event: MouseEvent) => {
      if (sortMenuRef.current !== null && !sortMenuRef.current.contains(event.target as Node)) {
        setSortMenuOpen(false);
      }
    };
    document.addEventListener("mousedown", handlePointerDown);
    return () => document.removeEventListener("mousedown", handlePointerDown);
  }, [sortMenuOpen]);

  const sortedItems = sortMediaItems(items, sortMode, sortAscending);
  const showPath = server.kind !== "emby" && server.kind !== "jellyfin";

  const chooseSort = (mode: MediaSortMode) => {
    if (mode === sortMode) onSortChange(mode, !sortAscending);
    else onSortChange(mode, true);
    setSortMenuOpen(false);
  };

  return (
    <div className="net-browser">
      <div className="net-browser-header">
        <button type="button" className="net-browser-back" onClick={onBack} title={t("webdav.back")} aria-label={t("webdav.back")}>
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M14.5 5 L8 12 L14.5 19" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
        <span className="net-browser-kind"><KindIcon kind={server.kind} /></span>
        <span className="net-browser-name">{server.name}</span>
        {showPath && (
          <span className="net-browser-path" title={currentPathLabel(pathStack)}>{currentPathLabel(pathStack)}</span>
        )}
        <span className="net-browser-spacer" />
        {addingFolder && (
          <span className="net-spinner" role="status" title={t("browser.adding-folder")} aria-label={t("browser.adding-folder")} />
        )}
        {isLoading && <span className="net-spinner" role="status" />}
        <div className="net-sort-anchor" ref={sortMenuRef}>
          <button
            type="button"
            className={`net-sort-button ${sortMenuOpen ? "active" : ""}`}
            onClick={() => setSortMenuOpen(!sortMenuOpen)}
            title={t("browser.sort")}
            aria-label={t("browser.sort")}
            aria-haspopup="menu"
            aria-expanded={sortMenuOpen}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M7 4 V20 M7 20 L3.5 16.5 M7 20 L10.5 16.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
              <path d="M17 20 V4 M17 4 L13.5 7.5 M17 4 L20.5 7.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </button>
          {sortMenuOpen && (
            <div className="net-sort-menu" role="menu">
              {(["name", "modified", "size"] as const).map((mode) => (
                <button
                  key={mode}
                  type="button"
                  role="menuitem"
                  className="net-sort-row"
                  onClick={() => chooseSort(mode)}
                >
                  {t(sortLabelKey(mode))}
                  {mode === sortMode && (
                    <span className="net-sort-arrow" aria-hidden="true">{sortAscending ? "↑" : "↓"}</span>
                  )}
                </button>
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="net-browser-content">
        {errorMessage !== null ? (
          <div className="net-error">
            <div className="net-error-message" role="alert">{errorMessage}</div>
            <button type="button" className="net-error-retry" onClick={onReload}>{t("webdav.retry")}</button>
          </div>
        ) : items.length === 0 && !isLoading ? (
          <div className="net-empty">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M3.5 6.5 A1.5 1.5 0 0 1 5 5 H9.5 L11.5 7.5 H19 A1.5 1.5 0 0 1 20.5 9 V17.5 A1.5 1.5 0 0 1 19 19 H5 A1.5 1.5 0 0 1 3.5 17.5 Z" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
            </svg>
            <div className="net-empty-message">{t("webdav.empty-folder")}</div>
          </div>
        ) : isLoading && items.length === 0 ? (
          <div className="net-browser-loading" role="status">
            <span className="net-spinner" />
          </div>
        ) : (
          <div className="net-browser-list" role="list">
            {sortedItems.map((item) => (
              <BrowserRow
                key={item.id}
                item={item}
                kind={server.kind}
                onEnterDirectory={onEnterDirectory}
                onPlay={onPlay}
                onAddFolderToPlaylist={onAddFolderToPlaylist}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function BrowserRow({
  item, kind, onEnterDirectory, onPlay, onAddFolderToPlaylist,
}: {
  item: MediaItem;
  kind: ServerSource["kind"];
  onEnterDirectory: (item: MediaItem) => void;
  onPlay: (item: MediaItem) => void;
  onAddFolderToPlaylist: (folder: MediaItem) => void;
}) {
  const { t } = useI18n();
  // The row itself is the affordance (mac: no per-row play badge). Folders
  // are always active; files the playability rule rejects (extension
  // whitelist / Emby media type) stay visible but disabled.
  const disabled = !item.isDirectory && !isPlayable(item, kind);
  const size = !item.isDirectory ? formatItemSize(item.size) : "";

  return (
    <button
      type="button"
      role="listitem"
      className={`net-browser-row ${disabled ? "disabled" : ""}`}
      disabled={disabled}
      onClick={() => {
        if (item.isDirectory) onEnterDirectory(item);
        else onPlay(item);
      }}
      onContextMenu={(event) => {
        if (!item.isDirectory) return;
        event.preventDefault();
        onAddFolderToPlaylist(item);
      }}
      title={item.isDirectory ? item.name : `${item.name}${size !== "" ? ` · ${size}` : ""}`}
    >
      <span className={`net-browser-row-icon ${item.isDirectory ? "folder" : ""}`}>
        {item.isDirectory ? (
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M3.5 6.5 A1.5 1.5 0 0 1 5 5 H9.5 L11.5 7.5 H19 A1.5 1.5 0 0 1 20.5 9 V17.5 A1.5 1.5 0 0 1 19 19 H5 A1.5 1.5 0 0 1 3.5 17.5 Z" fill="currentColor" />
          </svg>
        ) : kind === "emby" || kind === "jellyfin" ? (
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <rect x="3" y="5" width="18" height="14" rx="2" fill="none" stroke="currentColor" strokeWidth="1.6" />
            <path d="M10 9 L15 12 L10 15 Z" fill="currentColor" />
          </svg>
        ) : (
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M6 3.5 H14.5 L19 8 V20.5 H6 Z" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
            <path d="M14.5 3.5 V8 H19" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
          </svg>
        )}
      </span>
      <span className="net-browser-row-name">{item.name}</span>
      {size !== "" && <span className="net-browser-row-size">{size}</span>}
    </button>
  );
}
