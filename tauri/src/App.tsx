import { useState, useEffect, useRef, useCallback } from "react";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getVersion } from "@tauri-apps/api/app";
import { openUrl as openExternal } from "@tauri-apps/plugin-opener";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { getCurrentWindow } from "@tauri-apps/api/window";

import { applySnapshot, CommandGate, commandError, initialView, sameMedia, volumeAtClick, sliderValueAtKey } from "./player-state";
import type { StateSnapshot } from "./player-state";
import type { LoopMode } from "./components/PlaylistPanel";
import type { SidebarSection } from "./components/Sidebar";
import type { HistoryEntry, Bookmark } from "./library-state";
import { displayMediaTitle, PlaybackHistoryTracker } from "./library-state";
import { resolveSystemLanguage, useI18n } from "./i18n";
import PlaylistPanel from "./components/PlaylistPanel";
import ChaptersPanel from "./components/ChaptersPanel";
import HistoryPanel from "./components/HistoryPanel";
import BookmarksPanel from "./components/BookmarksPanel";
import Sidebar from "./components/Sidebar";
import KeyboardHandler from "./components/KeyboardHandler";
import SettingsPanel from "./components/SettingsPanel";
import NetworkPanel, { type NetworkTab } from "./components/NetworkPanel";
import PlayerIcon from "./components/PlayerIcon";
import PlaybackOptions from "./components/PlaybackOptions";
import { readSubtitleAutoLoad, rememberSubtitleAutoLoad } from "./components/SubtitleAutoLoadControl";
import type { SubtitleAutoLoad } from "./components/SubtitleAutoLoadControl";
import PlaybackTimeline from "./components/PlaybackTimeline";
import ClearLibraryDialog from "./components/ClearLibraryDialog";
import { useNativeVideoSurface, useViewingMode } from "./desktop-window";

const GITHUB_PROJECT_URL = "https://github.com/BrushLLM/brushllm-player";
const GITHUB_RELEASES_URL = "https://github.com/BrushLLM/brushllm-player/releases";

const SUBTITLE_EXTENSIONS = new Set(["srt", "ass", "ssa", "sub", "idx", "vtt", "sup"]);

const compactWindow = window.matchMedia("(width < 800px)");

function fileExtension(path: string): string {
  const dot = path.lastIndexOf(".");
  return dot >= 0 ? path.slice(dot + 1).toLowerCase() : "";
}

export default function App() {
  const { t, lang } = useI18n();
  useEffect(() => {
    document.documentElement.lang = lang === "system" ? resolveSystemLanguage(navigator.languages) : lang;
  }, [lang]);
  const [view, setView] = useState(initialView);
  const viewRef = useRef(initialView);
  const [invokeError, setInvokeError] = useState<{ generation: number; message: string } | null>(null);
  const [aboutOpen, setAboutOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [appVersion, setAppVersion] = useState<string | null>(null);
  const [versionLoading, setVersionLoading] = useState(true);
  const aboutDialogRef = useRef<HTMLElement>(null);
  const aboutCloseRef = useRef<HTMLButtonElement>(null);
  const mounted = useRef(false);
  const commandGate = useRef(new CommandGate());
  const [libraryError, setLibraryError] = useState<string | null>(null);
  const historyTracker = useRef(new PlaybackHistoryTracker());
  const historyWrites = useRef<Promise<unknown>>(Promise.resolve());
  const reportLibraryError = useCallback((error: unknown) => {
    if (mounted.current) setLibraryError(commandError(error).message);
  }, []);
  const state = view.player;

  const [sidebarTab, setSidebarTab] = useState<SidebarSection>("playlist");
  const [autoCompact, setAutoCompact] = useState(compactWindow.matches);
  const [sidebarPreferences, setSidebarPreferences] = useState<Partial<Record<"narrow" | "wide", boolean>>>({});
  const widthClass = autoCompact ? "narrow" : "wide";
  const sidebarCompact = sidebarPreferences[widthClass] ?? autoCompact;
  const setSidebarCompact = (compact: boolean) => {
    setSidebarPreferences((previous) => ({ ...previous, [widthClass]: compact }));
  };
  const [subtitleAutoLoad, setSubtitleAutoLoad] = useState(readSubtitleAutoLoad);
  const [savingSubtitleAutoLoad, setSavingSubtitleAutoLoad] = useState(false);
  const [networkTab, setNetworkTab] = useState<NetworkTab | null>(null);
  const [clearRequest, setClearRequest] = useState<{ label: string; action: () => void } | null>(null);
  const modalOpen = aboutOpen || settingsOpen || networkTab !== null || clearRequest !== null;
  // Library data (history is global; bookmarks are per-file).
  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [bookmarks, setBookmarks] = useState<Bookmark[]>([]);
  const restoredPlaylist = useRef<Promise<unknown> | null>(null);

  const closeAbout = useCallback(() => setAboutOpen(false), []);
  const closeSettings = useCallback(() => setSettingsOpen(false), []);
  const closeNetwork = useCallback(() => setNetworkTab(null), []);

  useEffect(() => {
    const sync = (event: MediaQueryListEvent) => setAutoCompact(event.matches);
    compactWindow.addEventListener("change", sync);
    return () => compactWindow.removeEventListener("change", sync);
  }, []);

  useEffect(() => {
    if (!aboutOpen || appVersion !== null) return;
    let cancelled = false;
    setVersionLoading(true);
    void getVersion()
      .then((version) => {
        if (!cancelled) setAppVersion(version || "Unavailable");
      })
      .catch(() => {
        if (!cancelled) setAppVersion("Unavailable");
      })
      .finally(() => {
        if (!cancelled) setVersionLoading(false);
      });
    return () => { cancelled = true; };
  }, [aboutOpen, appVersion]);

  useEffect(() => {
    if (!aboutOpen) return;
    const previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        closeAbout();
        return;
      }
      if (event.key === "Tab") {
        const focusable = aboutDialogRef.current?.querySelectorAll<HTMLElement>(
          "button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])",
        );
        if (!focusable?.length) return;
        const items = Array.from(focusable);
        const current = document.activeElement as HTMLElement | null;
        const index = current ? items.indexOf(current) : -1;
        const next = event.shiftKey
          ? (index <= 0 ? items.length - 1 : index - 1)
          : (index === -1 || index === items.length - 1 ? 0 : index + 1);
        event.preventDefault();
        items[next].focus();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    aboutCloseRef.current?.focus();
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      if (previouslyFocused?.isConnected) previouslyFocused.focus();
    };
  }, [aboutOpen, closeAbout]);

  const acceptSnapshot = useCallback((snapshot: StateSnapshot) => {
    const previous = viewRef.current;
    const next = applySnapshot(previous, snapshot);
    if (next === previous) return;

    // Serialize record/update so a fast EOF cannot save progress before the row exists.
    for (const write of historyTracker.current.accept(next, {
      ended: snapshot.endFile !== null,
      hasPosition: typeof snapshot.properties["time-pos"] === "number",
    })) {
      historyWrites.current = historyWrites.current
        .then(() => invoke(write.command, write.args))
        .catch(reportLibraryError);
    }

    if (!sameMedia(next, previous) || !next.connected) {
      commandGate.current.invalidate();
      setInvokeError(null);
    }
    viewRef.current = next;
    setView(next);
  }, [reportLibraryError]);
  const showError = useCallback((error: unknown, fallback: number, sequence: number) => {
    const parsed = commandError(error);
    const generation = parsed.generation ?? fallback;
    // An old request failing after a reconnect cannot poison the new session.
    if (mounted.current && commandGate.current.accepts(sequence) && generation >= viewRef.current.generation) {
      setInvokeError({ generation, message: parsed.message });
    }
  }, []);
  const reportDesktopError = useCallback((error: unknown) => {
    showError(error, viewRef.current.generation, commandGate.current.begin());
  }, [showError]);
  const { mode, changeMode } = useViewingMode(state.onTop, reportDesktopError);
  const viewing = mode !== "windowed";
  const hasVideo = state.tracks.some(({ type, selected }) => type === "video" && selected);

  const runCommand = useCallback(async (command: string, args?: Record<string, unknown>) => {
    const generation = viewRef.current.generation;
    const sequence = commandGate.current.begin();
    setInvokeError(null);
    try {
      await invoke(command, args);
      if (mounted.current && commandGate.current.accepts(sequence)) setInvokeError(null);
    }
    catch (error) { showError(error, generation, sequence); }
  }, [showError]);

  const changeSubtitleAutoLoad = async (mode: SubtitleAutoLoad) => {
    setSavingSubtitleAutoLoad(true);
    try {
      if (isTauri()) await invoke("set_subtitle_auto_load", { mode });
      setSubtitleAutoLoad(mode);
      rememberSubtitleAutoLoad(mode);
    } catch (error) {
      reportDesktopError(error);
    } finally {
      setSavingSubtitleAutoLoad(false);
    }
  };
  const subtitleAutoLoadControl = {
    mode: subtitleAutoLoad, pending: savingSubtitleAutoLoad, onChange: changeSubtitleAutoLoad,
  };

  const openDroppedPaths = useCallback(async (paths: string[]) => {
    const subtitles = paths.filter((path) => SUBTITLE_EXTENSIONS.has(fileExtension(path)));
    const media = paths.filter((path) => !SUBTITLE_EXTENSIONS.has(fileExtension(path)));
    if (media.length > 0) await runCommand("load_files", { paths: media });
    for (const path of subtitles) await runCommand("add_subtitle", { path });
  }, [runCommand]);

  const restorePlaylist = useCallback(() => {
    restoredPlaylist.current ??= invoke("playlist_restore").catch(() => {});
    return restoredPlaylist.current;
  }, []);

  // Also restore when opening a file recovers from an initial mpv startup failure.
  useEffect(() => {
    if (view.ready) void restorePlaylist();
  }, [restorePlaylist, view.ready]);

  useEffect(() => {
    mounted.current = true;
    let cancelled = false;
    let opened = false;
    const unlisten: (() => void)[] = [];
    let sequence = commandGate.current.begin();
    if (!isTauri()) return () => { mounted.current = false; };
    let pendingOpens = Promise.resolve();
    const drainOpenRequests = () => {
      if (!opened || cancelled) return;
      pendingOpens = pendingOpens.then(async () => {
        if (cancelled) return;
        const paths = await invoke<string[]>("take_open_files");
        if (!cancelled && paths.length) await openDroppedPaths(paths);
      }).catch((error) => { if (!cancelled) reportDesktopError(error); });
    };
    const subscriptions = [
      listen<StateSnapshot>("mpv-state", (event) => {
        if (!cancelled) acceptSnapshot(event.payload);
      }),
      listen("system-open-files", drainOpenRequests),
    ].map((subscription) => subscription.then((stop) => {
      if (cancelled) stop();
      else unlisten.push(stop);
    }));
    void Promise.all(subscriptions).then(async () => {
      if (cancelled) return;
      sequence = commandGate.current.begin();
      const snapshot = await invoke<StateSnapshot>("player_ready", { subtitleAutoLoad: readSubtitleAutoLoad() });
      if (cancelled) return;
      acceptSnapshot(snapshot);
      // Restore before applying an Explorer activation, which may replace the playlist.
      await restorePlaylist();
    }).catch((error) => {
      if (!cancelled) showError(error, viewRef.current.generation, sequence);
    }).finally(() => {
      opened = true;
      drainOpenRequests();
    });
    return () => {
      cancelled = true;
      mounted.current = false;
      commandGate.current.invalidate();
      unlisten.forEach((stop) => stop());
    };
  }, [acceptSnapshot, openDroppedPaths, reportDesktopError, restorePlaylist, showError]);

  useEffect(() => {
    if (!isTauri()) return;
    let active = true;
    let unlisten: (() => void) | undefined;
    void getCurrentWebview().onDragDropEvent((event) => {
      if (active && event.payload.type === "drop") void openDroppedPaths(event.payload.paths);
    }).then((stop) => {
      if (active) unlisten = stop;
      else stop();
    }).catch((error) => { if (active) reportDesktopError(error); });
    return () => { active = false; unlisten?.(); };
  }, [openDroppedPaths, reportDesktopError]);

  // History list: refresh when the history tab becomes visible and after
  // every media change (a play was recorded).
  useEffect(() => {
    if (!isTauri() || viewing || sidebarCompact || sidebarTab !== "history") return;
    let cancelled = false;
    void historyWrites.current.then(() => invoke<HistoryEntry[]>("history_list"))
      .then((entries) => { if (!cancelled) setHistory(entries); })
      .catch((error) => { if (!cancelled) reportLibraryError(error); });
    return () => { cancelled = true; };
  }, [viewing, sidebarCompact, sidebarTab, state.mediaPath, state.idle, view.generation, view.mediaEpoch]);

  // Bookmarks are per-file: refresh on tab open and on media change.
  useEffect(() => {
    setBookmarks([]);
    if (!isTauri() || viewing || sidebarCompact || sidebarTab !== "bookmarks" || !state.mediaPath) return;
    let cancelled = false;
    void invoke<Bookmark[]>("bookmark_list", { path: state.mediaPath })
      .then((list) => { if (!cancelled) setBookmarks(list); })
      .catch((error) => { if (!cancelled) reportLibraryError(error); });
    return () => { cancelled = true; };
  }, [viewing, sidebarCompact, sidebarTab, state.mediaPath, view.generation, view.mediaEpoch]);

  // Dismissable error: the invoke-side error clears on dismiss or as soon
  // as a fresh snapshot reports a healthy connection; snapshot-side errors
  // (view.error) already clear on the next clean snapshot.
  useEffect(() => {
    if (view.connected) setInvokeError(null);
  }, [view.connected]);

  const [dismissedFailure, setDismissedFailure] = useState<string | null>(null);
  const failureKey = view.generation + "/" + view.mediaEpoch;
  const loadError = failureKey === dismissedFailure ? null : view.error;
  const rawError = invokeError && invokeError.generation >= view.generation ? invokeError.message : loadError;
  // Localize the mpv end-file error (technical English like "no audio or
  // video data played"); the raw string stays as the tooltip detail.
  const isMpvLoadError = !libraryError && !invokeError && loadError !== null;
  const error = libraryError || (isMpvLoadError ? t("player.load-failed") : rawError);
  const errorDetail = isMpvLoadError ? rawError : null;
  const dismissError = () => {
    if (isMpvLoadError) setDismissedFailure(failureKey);
    setLibraryError(null);
    setInvokeError(null);
  };
  const { stageRef, output } = useNativeVideoSurface(
    view.ready && !view.loading && !state.idle && hasVideo && !modalOpen && loadError === null,
    reportDesktopError,
  );

  const { generation, mediaEpoch } = view;
  const seekFromTimeline = useCallback((position: number) => {
    const current = viewRef.current;
    if (current.ready && !current.loading && !current.player.idle && sameMedia({ generation, mediaEpoch }, current)) {
      void runCommand("seek", { position });
    }
  }, [generation, mediaEpoch, runCommand]);

  const togglePlay = () => runCommand("toggle_pause");
  const setVolume = (v: number) => runCommand("set_property", { name: "volume", value: String(v) });
  const toggleMute = () => runCommand("set_property", { name: "mute", value: state.muted ? "no" : "yes" });
  const setProperty = (name: string, value: string) => runCommand("set_property", { name, value });
  const sendMpv = (args: (string | number)[]) => runCommand("send_command", { args });

  // Playlist actions (IINA SidebarPlaylistPane command surface).
  const playPlaylistIndex = (index: number) => sendMpv(["playlist-play-index", index]);
  const removePlaylistIndex = (index: number) => sendMpv(["playlist-remove", index]);
  const clearPlaylist = () => runCommand("playlist_command", { op: "clear" });
  const shufflePlaylist = () => runCommand("playlist_command", { op: "shuffle" });
  const setLoopMode = (mode: LoopMode) => {
    setProperty("loop-file", mode === "file" ? "inf" : "no");
    setProperty("loop-playlist", mode === "playlist" ? "inf" : "no");
  };
  const selectChapter = (index: number) => {
    const chapter = state.chapters[index];
    if (chapter) void runCommand("seek", { position: chapter.time });
  };
  // Always on top: dual-track like IINA isOntop — the OS window level and
  // the mpv "ontop" property stay in sync.
  const toggleOnTop = () => {
    const next = !state.onTop;
    if (isTauri()) void getCurrentWindow().setAlwaysOnTop(next).catch((error) => showError(error, view.generation, commandGate.current.begin()));
    setProperty("ontop", next ? "yes" : "no");
  };

  const showSidebarSection = (section: SidebarSection) => {
    setSidebarTab(section);
    if (sidebarCompact) setSidebarCompact(false);
  };
  const togglePlaylistSidebar = () => {
    if (viewing) {
      void changeMode("windowed");
      showSidebarSection("playlist");
    } else if (sidebarTab === "playlist" && !sidebarCompact) {
      setSidebarCompact(true);
    } else {
      showSidebarSection("playlist");
    }
  };
  const openFiles = () => {
    if (isTauri()) void runCommand("open_file_dialog");
    else reportLibraryError(t("player.desktop-required"));
  };

  // Library actions.
  const playHistoryEntry = (path: string) => historyWrites.current.then(() => runCommand("history_play", { path }));
  const removeHistoryEntry = (path: string) => {
    void invoke("history_remove", { path })
      .then(() => setHistory((entries) => entries.filter((entry) => entry.path !== path)))
      .catch(reportLibraryError);
  };
  const clearHistory = () => {
    void invoke("history_clear").then(() => setHistory([])).catch(reportLibraryError);
  };
  const addBookmark = () => {
    if (!state.mediaPath || state.idle) return;
    const media = { generation: view.generation, mediaEpoch: view.mediaEpoch };
    void invoke<Bookmark>("bookmark_add", {
      path: state.mediaPath, time: state.position, title: state.mediaTitle || state.fileName || state.mediaPath,
    }).then((bookmark) => {
      if (sameMedia(media, viewRef.current)) setBookmarks((list) => [...list, bookmark].sort((a, b) => a.time - b.time));
    }).catch(reportLibraryError);
  };
  const removeBookmark = (id: number) => {
    void invoke("bookmark_remove", { id })
      .then(() => setBookmarks((list) => list.filter((bookmark) => bookmark.id !== id)))
      .catch(reportLibraryError);
  };
  const clearBookmarks = () => {
    if (!state.mediaPath) return;
    const path = state.mediaPath;
    void invoke("bookmark_clear", { path }).then(() => {
      if (viewRef.current.player.mediaPath === path) setBookmarks([]);
    }).catch(reportLibraryError);
  };

  const toggleFullscreen = useCallback(() => {
    if (output === "detached") void runCommand("send_command", { args: ["cycle", "fullscreen"] });
    else void changeMode(mode === "fullscreen" ? "windowed" : "fullscreen");
  }, [output, runCommand, changeMode, mode]);

  useEffect(() => {
    if (output !== "embedded") return;
    let active = true;
    const subscriptions = [
      listen("video-toggle-fullscreen", () => { if (active && !modalOpen) toggleFullscreen(); }),
      listen<string[]>("video-files-dropped", (event) => {
        if (active && !modalOpen) void openDroppedPaths(event.payload);
      }),
    ];
    for (const subscription of subscriptions) {
      void subscription.catch((error) => { if (active) reportDesktopError(error); });
    }
    return () => {
      active = false;
      for (const subscription of subscriptions) void subscription.then((stop) => stop()).catch(() => {});
    };
  }, [output, modalOpen, openDroppedPaths, reportDesktopError, toggleFullscreen]);

  useEffect(() => {
    if (modalOpen || mode === "windowed") return;
    const escape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      void changeMode("windowed");
    };
    window.addEventListener("keydown", escape);
    return () => window.removeEventListener("keydown", escape);
  }, [changeMode, modalOpen, mode]);

  const handleKeyAction = useCallback(({ command, args }: { command: string; args?: string[] }) => {
    if (command === "toggle_fullscreen") toggleFullscreen();
    else if (command === "toggle_pause") void runCommand("toggle_pause");
    else if (command === "seek_relative") void runCommand("seek_relative", { seconds: Number(args?.[0]) });
    else if (command === "set_property") void runCommand("set_property", { name: args?.[0], value: args?.[1] });
    else if (command === "screenshot") void runCommand("screenshot");
    else if (command === "send_command") void runCommand("send_command", { args: args ?? [] });
  }, [runCommand, toggleFullscreen]);

  const playLabel = t(state.paused || state.idle ? "controls.play" : "controls.pause");
  const muteLabel = t(state.muted ? "controls.unmute" : "controls.mute");
  const sidebarLabel = t(sidebarCompact ? "player.sidebar-expand" : "player.sidebar-collapse");
  const fullscreenLabel = t(mode === "fullscreen" ? "player.fullscreen-exit" : "controls.fullscreen");
  const miniLabel = t(mode === "mini" ? "controls.pip-exit" : "controls.pip");
  const mediaTitle = displayMediaTitle(state.mediaTitle) || displayMediaTitle(state.fileName) || t("player.workspace");
  const canSeek = view.ready && !view.loading && !state.idle && state.duration > 0;
  const playButton = (
    <button type="button" className="play-btn" onClick={togglePlay}
      disabled={!view.ready || state.idle} aria-label={playLabel} title={playLabel}>
      <PlayerIcon name={state.paused || state.idle ? "play" : "pause"} />
    </button>
  );

  return (
    <div className="app" data-viewing={mode}>
      <KeyboardHandler enabled={!modalOpen} onAction={handleKeyAction} onTogglePlaylist={togglePlaylistSidebar} />

      {!viewing && (
        <Sidebar compact={sidebarCompact} section={sidebarTab} onSelect={showSidebarSection}
          onFiles={openFiles} onStream={() => setNetworkTab("stream")} onServers={() => setNetworkTab("servers")}
          onSettings={() => setSettingsOpen(true)} onAbout={() => setAboutOpen(true)}>
          {sidebarTab === "playlist" && (
            <PlaylistPanel entries={state.playlist} onPlay={playPlaylistIndex} onRemove={removePlaylistIndex}
              onClear={() => setClearRequest({ label: "panel.playlist.clear", action: clearPlaylist })} onShuffle={shufflePlaylist} loopFile={state.loopFile}
              loopPlaylist={state.loopPlaylist} onLoop={setLoopMode} />
          )}
          {sidebarTab === "chapters" && (
            <ChaptersPanel chapters={state.chapters} currentChapter={state.currentChapter} onSelect={selectChapter} />
          )}
          {sidebarTab === "history" && (
            <HistoryPanel entries={history} onPlay={playHistoryEntry} onRemove={removeHistoryEntry}
              onClear={() => setClearRequest({ label: "panel.history.clear", action: clearHistory })} />
          )}
          {sidebarTab === "bookmarks" && (
            <BookmarksPanel bookmarks={bookmarks} onAdd={addBookmark} onRemove={removeBookmark}
              onClear={() => setClearRequest({ label: "panel.bookmarks.clear", action: clearBookmarks })}
              onSelect={(time) => runCommand("seek", { position: time })} />
          )}
        </Sidebar>
      )}

      <main className="player-workspace" aria-label={t("player.workspace")}>
        {!viewing && (
          <header className="workspace-header">
            <button className="tool-btn" type="button" aria-label={sidebarLabel} title={sidebarLabel}
              aria-expanded={!sidebarCompact} aria-controls="sidebar-content"
              onClick={() => setSidebarCompact(!sidebarCompact)}>
              <PlayerIcon name="sidebar" />
            </button>
            <h1 title={state.idle ? undefined : mediaTitle}>{state.idle ? t("player.workspace") : mediaTitle}</h1>
            {!state.idle && (
              <button type="button" className="workspace-open" onClick={openFiles}
                aria-label={t("player.open-files")} title={t("player.open-files")}>
                <PlayerIcon name="folder" />
                <span>{t("player.open-files")}</span>
              </button>
            )}
          </header>
        )}

        {error && (
          <div className="player-error" role="alert" title={errorDetail ?? undefined}>
            <span className="player-error-text">{error}</span>
            {isMpvLoadError && (
              <button className="player-error-recover" type="button" onClick={openFiles}>{t("player.open-files")}</button>
            )}
            <button type="button" className="player-error-dismiss" onClick={dismissError}
              aria-label={t("panel.cancel")} title={t("panel.cancel")}>
              <PlayerIcon name="close" />
            </button>
          </div>
        )}

        <div className="video-area" ref={stageRef} onDoubleClick={(event) => {
          if (event.target === event.currentTarget && !state.idle) toggleFullscreen();
        }}>
          {view.loading ? (
            <div className="video-status" role="status">{t("player.loading")}</div>
          ) : state.idle ? (
            <div className="empty-state">
              <span className="empty-screen-icon"><PlayerIcon name="screen" /></span>
              <h2>{t("player.open-hint")}</h2>
              <p>{t("player.drag-hint")}</p>
              <div className="empty-actions">
                <button type="button" className="open-primary" onClick={openFiles}>
                  <PlayerIcon name="folder" />
                  {t("player.open-files")}
                </button>
                {!viewing && sidebarCompact && (
                  <button type="button" className="open-sources" onClick={() => showSidebarSection("sources")}>
                    {t("player.sources")}
                  </button>
                )}
              </div>
            </div>
          ) : output !== "embedded" && hasVideo ? (
            <div className="video-status" role="status">
              <PlayerIcon name="screen" />
              <p>{t(output === "detached" ? "player.video-detached" : "player.video-native-mac")}</p>
            </div>
          ) : !hasVideo && state.tracks.some(({ type }) => type === "audio") ? (
            <div className="video-status">
              <PlayerIcon name="volume" />
              <p>{mediaTitle}</p>
            </div>
          ) : null}
        </div>

        <div className="control-bar">
          {viewing && playButton}
          <PlaybackTimeline key={failureKey + "/" + mode} position={state.position} duration={state.duration}
            abLoopA={state.abLoopA} abLoopB={state.abLoopB} canSeek={canSeek}
            showTimeHint={!viewing} onSeek={seekFromTimeline} />

          <div className="button-row">
            {!viewing && (
              <div className="transport-group">
                <button className="tool-btn" type="button" onClick={() => sendMpv(["playlist-prev", "weak"])}
                  disabled={state.playlistCount < 2 || !view.ready} aria-label={t("menu.previous")} title={t("menu.previous")}>
                  <PlayerIcon name="previous" />
                </button>
                {playButton}
                <button className="tool-btn" type="button" onClick={() => sendMpv(["playlist-next", "weak"])}
                  disabled={state.playlistCount < 2 || !view.ready} aria-label={t("menu.next")} title={t("menu.next")}>
                  <PlayerIcon name="next" />
                </button>
                <button className="tool-btn" type="button" onClick={() => runCommand("stop_playback")}
                  disabled={state.idle || !view.ready} aria-label={t("menu.stop")} title={t("menu.stop")}>
                  <PlayerIcon name="stop" />
                </button>
              </div>
            )}

            <div className="viewing-group">
              <div className="volume-control">
                <button className="tool-btn" type="button" onClick={toggleMute} disabled={!view.ready}
                  aria-label={muteLabel} title={muteLabel}>
                  <PlayerIcon name={state.muted ? "mute" : "volume"} />
                </button>
                {!viewing && (
                  <div className="volume-slider" role="slider" tabIndex={view.ready ? 0 : -1}
                    aria-label={t("controls.volume")} aria-valuemin={0} aria-valuemax={130}
                    aria-valuenow={state.volume} aria-valuetext={Math.round(state.volume) + "%"}
                    aria-disabled={!view.ready}
                    onKeyDown={(event) => {
                      if (event.ctrlKey || event.metaKey || event.altKey || !view.ready) return;
                      const volume = sliderValueAtKey(event.key, state.volume, 0, 130, 5);
                      if (volume === null) return;
                      event.preventDefault();
                      event.stopPropagation();
                      void setVolume(volume);
                    }}
                    onClick={(event) => {
                      if (!view.ready) return;
                      const volume = volumeAtClick(event);
                      if (volume !== null) void setVolume(volume);
                    }}>
                    <div className="volume-track">
                      <div className="volume-fill" style={{ width: (state.volume / 130 * 100) + "%" }} />
                    </div>
                  </div>
                )}
              </div>
              <div className="window-actions">
                {mode !== "fullscreen" && output !== "detached" && (
                  <button type="button" className="tool-btn" title={miniLabel}
                    aria-label={miniLabel} onClick={() => void changeMode(mode === "mini" ? "windowed" : "mini")}>
                    <PlayerIcon name={mode === "mini" ? "miniExit" : "mini"} />
                  </button>
                )}
                <button type="button" className="tool-btn" title={fullscreenLabel} aria-label={fullscreenLabel}
                  onClick={toggleFullscreen} disabled={output === "detached" && state.idle}>
                  <PlayerIcon name={mode === "fullscreen" ? "fullscreenExit" : "fullscreen"} />
                </button>
              </div>
            </div>
          </div>
        </div>
        {!viewing && (
          <PlaybackOptions state={state} ready={view.ready} modalOpen={modalOpen}
            subtitleAutoLoad={subtitleAutoLoadControl} onCommand={runCommand}
            onToggleOnTop={toggleOnTop} onShowChapters={() => showSidebarSection("chapters")} />
        )}
      </main>

      {clearRequest && (
        <ClearLibraryDialog label={t(clearRequest.label)} onClose={() => setClearRequest(null)}
          onConfirm={() => {
            setClearRequest(null);
            clearRequest.action();
          }} />
      )}

      {settingsOpen && <SettingsPanel onClose={closeSettings} subtitleAutoLoad={subtitleAutoLoadControl} />}

      {networkTab !== null && (
        <NetworkPanel initialTab={networkTab} onClose={closeNetwork}
          onPlayUrl={(url) => {
            if (isTauri()) void runCommand("open_url", { url });
            else reportLibraryError(t("player.desktop-required"));
          }}
          onEnqueued={() => showSidebarSection("playlist")} />
      )}

      {aboutOpen && (
        <div
          className="about-overlay"
          onClick={(event) => {
            if (event.target === event.currentTarget) closeAbout();
          }}
        >
          <section
            id="about-dialog"
            className="about-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="about-dialog-title"
            aria-describedby="about-dialog-description"
          >
            <div className="about-header">
              <div>
                <h2 id="about-dialog-title">BrushLLM Player</h2>
                <p className="about-version">
                  Version {versionLoading ? "Loading…" : appVersion ?? "Unavailable"}
                </p>
              </div>
              <button
                ref={aboutCloseRef}
                className="tool-btn about-close"
                onClick={closeAbout}
                aria-label={t("panel.cancel")}
                title={t("panel.cancel")}
              >
                <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
                  <line x1="6" y1="6" x2="18" y2="18" />
                  <line x1="18" y1="6" x2="6" y2="18" />
                </svg>
              </button>
            </div>

            <p id="about-dialog-description" className="about-description">Powered by mpv.</p>
            <p className="about-license">
              Licensed under the GNU General Public License, version 3 (GPL v3). You may copy,
              distribute, and modify this software under the terms of that license.
            </p>

            <div className="about-links" aria-label="Project links">
              <button className="about-link" type="button" onClick={() => void openExternal(GITHUB_PROJECT_URL)}>
                GitHub project
                <span aria-hidden="true">↗</span>
              </button>
              <button className="about-link" type="button" onClick={() => void openExternal(GITHUB_RELEASES_URL)}>
                Releases
                <span aria-hidden="true">↗</span>
              </button>
              <button className="about-link" type="button" onClick={() => void openExternal("https://github.com/BrushLLM/brushllm-player/blob/main/LICENSE")}>
                Full license
                <span aria-hidden="true">↗</span>
              </button>
            </div>
          </section>
        </div>
      )}
    </div>
  );
}
