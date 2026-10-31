// Network modal, ported from the mac NetworkPanel: a two-tab dialog
// (Stream URL | Media Servers) reusing the About overlay/dialog chrome.
// Tab 1 is a simplified StreamTab (URL + play + clipboard paste; the mac
// advanced UA/buffer section is dropped for V1 — the Rust backend has no
// per-request UA or buffer settings to bind). Tab 2 manages media servers
// through the Rust commands (servers_list/add/update/remove/browse/play/
// enqueue/test): a card list, a kind-aware add/edit form and a browser with
// back navigation, sorting, play and folder-to-playlist enqueue.

import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

import { useI18n } from "../i18n";
import type { MediaItem, MediaSortMode, ServerSource } from "../server-state";
import { isPlayable, sortMediaItems } from "../server-state";
import { serverErrorMessage } from "../server-state";
import StreamTab from "./network/StreamTab";
import ServerList from "./network/ServerList";
import AddServerForm from "./network/AddServerForm";
import BrowserView from "./network/BrowserView";

export interface NetworkPanelProps {
  onClose: () => void;
  /** Plays a direct URL (stream tab) — routed to the existing open_url. */
  onPlayUrl: (url: string) => void;
  /** Fired after a folder's playable files were enqueued, so the parent can
   *  open the playlist sidebar (mac brushPlayerShowPlaylist). */
  onEnqueued: () => void;
}

type ServersTabView =
  | { kind: "list" }
  | { kind: "form"; editing: ServerSource | null }
  | { kind: "browser"; serverId: string };

export default function NetworkPanel({ onClose, onPlayUrl, onEnqueued }: NetworkPanelProps) {
  const { t } = useI18n();
  const [tab, setTab] = useState<"stream" | "servers">("stream");
  const dialogRef = useRef<HTMLElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);

  // Servers tab state.
  const [servers, setServers] = useState<ServerSource[]>([]);
  const [view, setView] = useState<ServersTabView>({ kind: "list" });
  const [listError, setListError] = useState<string | null>(null);
  const [pathStack, setPathStack] = useState<string[]>([]);
  const [items, setItems] = useState<MediaItem[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [addingFolder, setAddingFolder] = useState(false);
  const [browseError, setBrowseError] = useState<string | null>(null);
  const [sortMode, setSortMode] = useState<MediaSortMode>("name");
  const [sortAscending, setSortAscending] = useState(true);
  // Request tokens: only the newest browse/enqueue may publish results.
  const browseToken = useRef(0);
  const folderToken = useRef(0);

  const browsingServer = view.kind === "browser" ? servers.find((s) => s.id === view.serverId) ?? null : null;

  const refreshServers = useCallback(() => {
    void invoke<ServerSource[]>("servers_list")
      .then((list) => setServers(list))
      .catch((error) => setListError(serverErrorMessage(error, t)));
  }, []);

  // Load the server list when the panel opens.
  useEffect(() => {
    refreshServers();
  }, [refreshServers]);

  // Escape / Tab focus trap / outside-click dismissal, same pattern as the
  // About and Settings dialogs.
  useEffect(() => {
    const previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        onClose();
        return;
      }
      if (event.key === "Tab") {
        const focusable = dialogRef.current?.querySelectorAll<HTMLElement>(
          "button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])",
        );
        if (!focusable?.length) return;
        const elements = Array.from(focusable);
        const current = document.activeElement as HTMLElement | null;
        const index = current ? elements.indexOf(current) : -1;
        const next = event.shiftKey
          ? (index <= 0 ? elements.length - 1 : index - 1)
          : (index === -1 || index === elements.length - 1 ? 0 : index + 1);
        event.preventDefault();
        elements[next].focus();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    closeRef.current?.focus();
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      browseToken.current += 1;
      folderToken.current += 1;
      if (previouslyFocused?.isConnected) previouslyFocused.focus();
    };
  }, [onClose]);

  // --- Browsing ---

  const browse = useCallback((serverId: string, path: string) => {
    const token = ++browseToken.current;
    setIsLoading(true);
    setBrowseError(null);
    setItems([]);
    void invoke<MediaItem[]>("servers_browse", { serverId, path })
      .then((loaded) => {
        if (browseToken.current !== token) return;
        setItems(loaded);
        setIsLoading(false);
      })
      .catch((error) => {
        if (browseToken.current !== token) return;
        setBrowseError(serverErrorMessage(error, t));
        setIsLoading(false);
      });
  }, []);

  const enterBrowser = useCallback((server: ServerSource) => {
    browseToken.current += 1;
    folderToken.current += 1;
    setIsLoading(false);
    setAddingFolder(false);
    setBrowseError(null);
    setItems([]);
    setPathStack([""]);
    setView({ kind: "browser", serverId: server.id });
    browse(server.id, "");
  }, [browse]);

  const reloadBrowser = useCallback(() => {
    if (view.kind !== "browser") return;
    const path = pathStack[pathStack.length - 1] ?? "";
    browse(view.serverId, path);
  }, [view, pathStack, browse]);

  const exitBrowser = useCallback(() => {
    browseToken.current += 1;
    folderToken.current += 1;
    setIsLoading(false);
    setAddingFolder(false);
    setView({ kind: "list" });
    refreshServers();
  }, [refreshServers]);

  const browserBack = useCallback(() => {
    if (view.kind !== "browser") return;
    if (pathStack.length > 1) {
      setPathStack((stack) => stack.slice(0, -1));
      const parent = pathStack[pathStack.length - 2] ?? "";
      browse(view.serverId, parent);
    } else {
      exitBrowser();
    }
  }, [view, pathStack, browse, exitBrowser]);

  const enterDirectory = useCallback((item: MediaItem) => {
    if (view.kind !== "browser") return;
    setPathStack((stack) => [...stack, item.id]);
    browse(view.serverId, item.id);
  }, [view, browse]);

  // --- Playing / enqueueing ---

  const playItem = useCallback((server: ServerSource, item: MediaItem) => {
    // Errors surface inside the panel (browse-style error row), not through
    // the global player error banner: a failed server play keeps the modal
    // open so the user can retry or pick another item.
    void invoke("servers_play", { serverId: server.id, itemId: item.id }).catch((error) => {
      setBrowseError(serverErrorMessage(error, t));
    });
  }, []);

  // Folder to playlist: browse the folder, filter playable items (sorted the
  // way the browser currently sorts), enqueue each, then notify the parent to
  // open the playlist sidebar (mac addFolderToPlaylist).
  const addFolderToPlaylist = useCallback((folder: MediaItem) => {
    if (view.kind !== "browser") return;
    const server = servers.find((s) => s.id === view.serverId);
    if (!server) return;
    const token = ++folderToken.current;
    setAddingFolder(true);
    setBrowseError(null);
    void invoke<MediaItem[]>("servers_browse", { serverId: server.id, path: folder.id })
      .then(async (children) => {
        if (folderToken.current !== token) return;
        const playable = sortMediaItems(children, sortMode, sortAscending)
          .filter((child) => !child.name.startsWith(".") && isPlayable(child, server.kind));
        if (playable.length === 0) {
          setAddingFolder(false);
          setBrowseError(t("webdav.empty-folder"));
          return;
        }
        let enqueued = 0;
        for (const child of playable) {
          try {
            await invoke("servers_enqueue", { serverId: server.id, itemId: child.id });
            enqueued += 1;
          } catch {
            // A single failed item does not abort the batch.
          }
        }
        if (folderToken.current !== token) return;
        setAddingFolder(false);
        if (enqueued > 0) onEnqueued();
        else setBrowseError(t("webdav.empty-folder"));
      })
      .catch((error) => {
        if (folderToken.current !== token) return;
        setAddingFolder(false);
        setBrowseError(serverErrorMessage(error, t));
      });
  }, [view, servers, sortMode, sortAscending, onEnqueued, t]);

  // --- Server CRUD ---

  const removeServer = useCallback((server: ServerSource) => {
    setListError(null);
    void invoke<boolean>("servers_remove", { serverId: server.id })
      .then(() => {
        setServers((list) => list.filter((entry) => entry.id !== server.id));
      })
      .catch((error) => setListError(serverErrorMessage(error, t)));
  }, []);

  const onFormSaved = useCallback((server: ServerSource) => {
    setView({ kind: "list" });
    refreshServers();
    enterBrowser(server);
  }, [refreshServers, enterBrowser]);

  return (
    <div
      className="about-overlay"
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <section
        id="network-dialog"
        className="about-dialog network-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="network-dialog-title"
        ref={dialogRef}
      >
        <div className="about-header">
          <h2 id="network-dialog-title" className="network-title">
            {tab === "stream" ? t("network.tab.url") : t("network.tab.servers")}
          </h2>
          <button
            ref={closeRef}
            className="tool-btn about-close"
            onClick={onClose}
            aria-label={t("panel.cancel")}
            title={t("panel.cancel")}
            autoFocus
          >
            <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
              <line x1="6" y1="6" x2="18" y2="18" />
              <line x1="18" y1="6" x2="6" y2="18" />
            </svg>
          </button>
        </div>

        <div className="net-tabs" role="tablist" aria-label={t("controls.network")}>
          <button
            type="button"
            role="tab"
            aria-selected={tab === "stream"}
            className={`net-tab ${tab === "stream" ? "active" : ""}`}
            onClick={() => setTab("stream")}
          >
            {t("network.tab.url")}
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === "servers"}
            className={`net-tab ${tab === "servers" ? "active" : ""}`}
            onClick={() => setTab("servers")}
          >
            {t("network.tab.servers")}
          </button>
        </div>

        {tab === "stream" ? (
          <StreamTab
            onPlay={(url) => {
              onClose();
              onPlayUrl(url);
            }}
          />
        ) : view.kind === "form" ? (
          <AddServerForm
            editing={view.editing}
            onSaved={onFormSaved}
            onCancel={() => setView({ kind: "list" })}
          />
        ) : browsingServer !== null ? (
          <BrowserView
            server={browsingServer}
            pathStack={pathStack}
            items={items}
            isLoading={isLoading}
            addingFolder={addingFolder}
            errorMessage={browseError}
            sortMode={sortMode}
            sortAscending={sortAscending}
            onSortChange={(mode, ascending) => {
              setSortMode(mode);
              setSortAscending(ascending);
            }}
            onBack={browserBack}
            onReload={reloadBrowser}
            onEnterDirectory={enterDirectory}
            onPlay={(item) => playItem(browsingServer, item)}
            onAddFolderToPlaylist={addFolderToPlaylist}
          />
        ) : (
          <div className="net-servers">
            {listError !== null && <div className="net-list-error" role="alert">{listError}</div>}
            <ServerList
              servers={servers}
              onConnect={enterBrowser}
              onEdit={(server) => setView({ kind: "form", editing: server })}
              onRemove={removeServer}
              onAdd={() => setView({ kind: "form", editing: null })}
            />
          </div>
        )}
      </section>
    </div>
  );
}
