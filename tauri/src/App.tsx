import { useState, useEffect, useRef, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getVersion } from "@tauri-apps/api/app";
import { openUrl as openExternal } from "@tauri-apps/plugin-opener";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { getCurrentWindow } from "@tauri-apps/api/window";

import { applySnapshot, CommandGate, commandError, initialView, sameMedia, trackFraction, volumeAtClick } from "./player-state";
import type { StateSnapshot } from "./player-state";
import type { LoopMode } from "./components/PlaylistPanel";
import PlaylistPanel from "./components/PlaylistPanel";
import ChaptersPanel from "./components/ChaptersPanel";
import TrackMenu from "./components/TrackMenu";
import VideoSettingsMenu from "./components/VideoSettingsMenu";
import VideoEqMenu from "./components/VideoEqMenu";
import KeyboardHandler from "./components/KeyboardHandler";

const GITHUB_PROJECT_URL = "https://github.com/BrushLLM/brushllm-player";
const GITHUB_RELEASES_URL = "https://github.com/BrushLLM/brushllm-player/releases";

const SUBTITLE_EXTENSIONS = new Set(["srt", "ass", "ssa", "sub", "idx", "vtt", "sup"]);

function formatTime(seconds: number): string {
  if (!isFinite(seconds) || seconds < 0) return "0:00";
  const total = Math.floor(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
  }
  return `${minutes}:${String(secs).padStart(2, "0")}`;
}

function fileExtension(path: string): string {
  const dot = path.lastIndexOf(".");
  return dot >= 0 ? path.slice(dot + 1).toLowerCase() : "";
}

export default function App() {
  const [view, setView] = useState(initialView);
  const viewRef = useRef(initialView);
  const [invokeError, setInvokeError] = useState<{ generation: number; message: string } | null>(null);
  const [scrubbing, setScrubbing] = useState(false);
  const [scrubPosition, setScrubPosition] = useState(0);
  const [aboutOpen, setAboutOpen] = useState(false);
  const [appVersion, setAppVersion] = useState<string | null>(null);
  const [versionLoading, setVersionLoading] = useState(true);
  const trackRef = useRef<HTMLDivElement>(null);
  const aboutDialogRef = useRef<HTMLElement>(null);
  const aboutCloseRef = useRef<HTMLButtonElement>(null);
  const dragCleanup = useRef<(() => void) | null>(null);
  const mounted = useRef(false);
  const commandGate = useRef(new CommandGate());
  const state = view.player;

  // New surfaces: sidebar (playlist/chapters), popups, URL dialog.
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [sidebarTab, setSidebarTab] = useState<"playlist" | "chapters">("playlist");
  const [trackMenu, setTrackMenu] = useState<"audio" | "sub" | null>(null);
  const [videoMenuOpen, setVideoMenuOpen] = useState(false);
  const [eqMenuOpen, setEqMenuOpen] = useState(false);
  const [urlOpen, setUrlOpen] = useState(false);
  const [urlInput, setUrlInput] = useState("");

  const closeAbout = useCallback(() => setAboutOpen(false), []);

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
    const next = applySnapshot(viewRef.current, snapshot);
    if (next === viewRef.current) return;
    if (!sameMedia(next, viewRef.current) || !next.connected) {
      dragCleanup.current?.();
      setScrubbing(false);
      commandGate.current.invalidate();
      setInvokeError(null);
    }
    viewRef.current = next;
    setView(next);
  }, []);
  const showError = useCallback((error: unknown, fallback: number, sequence: number) => {
    const parsed = commandError(error);
    const generation = parsed.generation ?? fallback;
    // An old request failing after a reconnect cannot poison the new session.
    if (mounted.current && commandGate.current.accepts(sequence) && generation >= viewRef.current.generation) {
      setInvokeError({ generation, message: parsed.message });
    }
  }, []);
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

  useEffect(() => {
    mounted.current = true;
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    let sequence = commandGate.current.begin();
    void (async () => {
      try {
        // Listener registration is awaited before readiness/snapshot acquisition.
        const stop = await listen<StateSnapshot>("mpv-state", (event) => {
          if (!cancelled) acceptSnapshot(event.payload);
        });
        if (cancelled) { stop(); return; }
        unlisten = stop;
        sequence = commandGate.current.begin();
        const snapshot = await invoke<StateSnapshot>("player_ready");
        if (!cancelled) acceptSnapshot(snapshot);
      } catch (error) {
        if (!cancelled) showError(error, viewRef.current.generation, sequence);
      }
    })();
    return () => {
      cancelled = true;
      mounted.current = false;
      commandGate.current.invalidate();
      unlisten?.();
      dragCleanup.current?.();
    };
  }, [acceptSnapshot, showError]);

  // Drag & drop: subtitle files go to sub-add, media files to the playlist
  // (IINA VideoView drag behavior: classify by extension, batch-load media).
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    void getCurrentWebview().onDragDropEvent((event) => {
      if (event.payload.type !== "drop") return;
      const paths = event.payload.paths;
      const subtitles = paths.filter((path) => SUBTITLE_EXTENSIONS.has(fileExtension(path)));
      const media = paths.filter((path) => !SUBTITLE_EXTENSIONS.has(fileExtension(path)));
      if (media.length > 0) void runCommand("load_files", { paths: media });
      for (const path of subtitles) void runCommand("add_subtitle", { path });
    }).then((stop) => {
      if (cancelled) stop();
      else unlisten = stop;
    });
    return () => { cancelled = true; unlisten?.(); };
  }, [runCommand]);

  const error = invokeError && invokeError.generation >= view.generation ? invokeError.message : view.error;

  const effectivePosition = scrubbing ? scrubPosition : state.position;
  const progress = state.duration > 0 ? Math.min(effectivePosition / state.duration, 1) : 0;

  // Progress scrubbing sends one acknowledged seek at mouse-up. Geometry is
  // bounded and a reconnect/unmount cancels the old gesture.
  const handleTrackMouseDown = useCallback((e: React.MouseEvent) => {
    if (!trackRef.current || state.duration <= 0 || !view.ready || state.idle) return;
    const rect = trackRef.current.getBoundingClientRect();
    const fraction = trackFraction(e.clientX, rect.left, rect.width);
    if (fraction === null) return;
    dragCleanup.current?.();
    setScrubbing(true);
    setScrubPosition(fraction * state.duration);
    const media = { generation: view.generation, mediaEpoch: view.mediaEpoch };
    const onMouseMove = (e: MouseEvent) => {
      const fraction = trackFraction(e.clientX, rect.left, rect.width);
      if (fraction !== null) setScrubPosition(fraction * state.duration);
    };
    const cleanup = () => {
      window.removeEventListener("mousemove", onMouseMove);
      window.removeEventListener("mouseup", onMouseUp);
      dragCleanup.current = null;
    };
    const onMouseUp = (e: MouseEvent) => {
      const fraction = trackFraction(e.clientX, rect.left, rect.width);
      setScrubbing(false);
      cleanup();
      if (fraction !== null && sameMedia(media, viewRef.current) && viewRef.current.connected) {
        void runCommand("seek", { position: fraction * state.duration });
      }
    };
    dragCleanup.current = cleanup;
    window.addEventListener("mousemove", onMouseMove);
    window.addEventListener("mouseup", onMouseUp);
  }, [state.duration, state.idle, view.ready, view.generation, view.mediaEpoch, runCommand]);

  const togglePlay = () => runCommand("toggle_pause");
  const seekRelative = (s: number) => runCommand("seek_relative", { seconds: s });
  const setVolume = (v: number) => runCommand("set_property", { name: "volume", value: String(v) });
  const setSpeed = (s: number) => runCommand("set_property", { name: "speed", value: String(s) });
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
  const selectTrack = (kind: "audio" | "sub", id: number | null) =>
    setProperty(kind === "audio" ? "aid" : "sid", id === null ? "no" : String(id));

  // A-B loop: the mpv "ab-loop" command cycles set-A -> set-B -> clear
  // (IINA PlayerCore.abLoop three-state cycle).
  const abLoopActive = state.abLoopA !== null || state.abLoopB !== null;
  const toggleAbLoop = () => sendMpv(["ab-loop"]);

  // Always on top: dual-track like IINA isOntop — the OS window level and
  // the mpv "ontop" property stay in sync.
  const toggleOnTop = () => {
    const next = !state.onTop;
    void getCurrentWindow().setAlwaysOnTop(next);
    setProperty("ontop", next ? "yes" : "no");
  };

  const toggleSidebar = (tab: "playlist" | "chapters") => {
    if (sidebarOpen && sidebarTab === tab) setSidebarOpen(false);
    else { setSidebarTab(tab); setSidebarOpen(true); }
  };

  const submitUrl = () => {
    const trimmed = urlInput.trim();
    if (!trimmed) return;
    // IINA OpenURLWindowController: default missing scheme to http://.
    const url = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(trimmed) ? trimmed : `http://${trimmed}`;
    setUrlOpen(false);
    setUrlInput("");
    void runCommand("open_url", { url });
  };

  // Keyboard actions (keymap ported from IINA's default input.conf).
  const handleKeyAction = useCallback(({ command, args }: { command: string; args?: string[] }) => {
    if (command === "toggle_pause") runCommand("toggle_pause");
    else if (command === "seek_relative") runCommand("seek_relative", { seconds: Number(args?.[0]) });
    else if (command === "set_property") runCommand("set_property", { name: args?.[0], value: args?.[1] });
    else if (command === "screenshot") runCommand("screenshot");
    else if (command === "send_command") runCommand("send_command", { args: args ?? [] });
  }, [runCommand]);

  const anyMenuOpen = trackMenu !== null || videoMenuOpen || eqMenuOpen;

  return (
    <div className="app">
      <KeyboardHandler
        enabled={!aboutOpen && !urlOpen}
        onAction={handleKeyAction}
        onTogglePlaylist={() => toggleSidebar("playlist")}
      />

      <div className="video-area" onDoubleClick={() => sendMpv(["cycle", "fullscreen"])}>
        {error && <div className="player-error" role="alert">{error}</div>}
        {!view.connected && !error && <div className="connection-status" role="status">Open a file to connect or restart the player</div>}
        {state.idle && (
          <div className="empty-state" onClick={() => runCommand("open_file_dialog")} style={{ cursor: "pointer" }}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
              <rect x="2" y="5" width="20" height="14" rx="2" />
              <polygon points="10,9 16,12 10,15" fill="currentColor" />
            </svg>
            <div className="hint">Open a media file to start playing</div>
          </div>
        )}

        {sidebarOpen && sidebarTab === "playlist" && (
          <PlaylistPanel
            visible
            entries={state.playlist}
            onPlay={playPlaylistIndex}
            onRemove={removePlaylistIndex}
            onClear={clearPlaylist}
            onShuffle={shufflePlaylist}
            loopFile={state.loopFile}
            loopPlaylist={state.loopPlaylist}
            onLoop={setLoopMode}
          />
        )}
        {sidebarOpen && sidebarTab === "chapters" && (
          <ChaptersPanel
            chapters={state.chapters}
            currentChapter={state.currentChapter}
            onSelect={selectChapter}
          />
        )}
      </div>

      <div className="control-bar">
        <div className="progress-row">
          <span className="time-label">{formatTime(effectivePosition)}</span>
          <div
            ref={trackRef}
            className="progress-track"
            onMouseDown={handleTrackMouseDown}
          >
            <div className="progress-bg">
              <div className="progress-fill" style={{ width: `${progress * 100}%` }} />
            </div>
            {state.abLoopA !== null && state.duration > 0 && (
              <div className="ab-marker" style={{ left: `${(state.abLoopA / state.duration) * 100}%` }} title="A" />
            )}
            {state.abLoopB !== null && state.duration > 0 && (
              <div className="ab-marker" style={{ left: `${(state.abLoopB / state.duration) * 100}%` }} title="B" />
            )}
            <div className="progress-knob" style={{ left: `${progress * 100}%` }} />
          </div>
          <span className="time-label dim">{formatTime(state.duration)}</span>
        </div>

        <div className="button-row">
          <button className="tool-btn" onClick={() => runCommand("open_file_dialog")} title="Open…">📂</button>
          <button className="tool-btn" onClick={() => sendMpv(["playlist-prev", "weak"])} disabled={state.playlistCount < 2 || !view.ready} title="Previous">
            ⏮
          </button>
          <button
            className={`play-btn ${!state.paused ? "playing" : ""}`}
            onClick={togglePlay}
            disabled={state.idle || !view.ready}
            title={state.paused ? "Play" : "Pause"}
          >
            {state.paused ? "▶" : "⏸"}
          </button>
          <button className="tool-btn" onClick={() => sendMpv(["playlist-next", "weak"])} disabled={state.playlistCount < 2 || !view.ready} title="Next">
            ⏭
          </button>
          <button className="tool-btn" onClick={() => runCommand("stop_playback")} disabled={state.idle || !view.ready} title="Stop">
            ⏹
          </button>
          <button className="tool-btn" onClick={() => seekRelative(-5)} title="Back 5s">«</button>
          <button className="tool-btn" onClick={() => seekRelative(5)} title="Forward 5s">»</button>
          <button className="tool-btn" onClick={() => sendMpv(["frame-back-step"])} disabled={state.idle || !view.ready || state.paused === false} title="Frame back (,)">«·</button>
          <button className="tool-btn" onClick={() => sendMpv(["frame-step"])} disabled={state.idle || !view.ready} title="Frame forward (.)">·»</button>
          <button
            className={`tool-btn ${abLoopActive ? "active" : ""}`}
            onClick={toggleAbLoop}
            disabled={state.idle || !view.ready}
            title="A-B loop (l)"
          >
            AB
          </button>
          <button className="tool-btn" onClick={() => runCommand("screenshot")} disabled={state.idle || !view.ready} title="Screenshot (s)">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M4 8 H8 L10 5 H14 L16 8 H20 V19 H4 Z" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
              <circle cx="12" cy="13" r="3.4" fill="none" stroke="currentColor" strokeWidth="1.6" />
            </svg>
          </button>

          <div className="spacer" />

          <span
            className={`speed-label ${state.speed !== 1 ? "active" : ""}`}
            onClick={() => {
              const speeds = [0.5, 0.75, 1, 1.25, 1.5, 2];
              const idx = speeds.indexOf(state.speed);
              const next = speeds[(idx + 1) % speeds.length];
              setSpeed(next);
            }}
            title="Playback speed"
          >
            {state.speed === 1 ? "1×" : `${state.speed}×`}
          </span>

          <span className="menu-anchor">
            <button className="tool-btn" onClick={() => setTrackMenu(trackMenu === "audio" ? null : "audio")} disabled={!view.ready} title="Audio tracks">
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M4 13 Q4 5 12 5 Q20 5 20 13" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
                <rect x="3" y="13" width="4" height="7" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.6" />
                <rect x="17" y="13" width="4" height="7" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.6" />
              </svg>
            </button>
            {trackMenu === "audio" && (
              <TrackMenu kind="audio" tracks={state.tracks} currentId={state.audioTrackId}
                onSelect={(id) => selectTrack("audio", id)} onClose={() => setTrackMenu(null)} />
            )}
          </span>
          <span className="menu-anchor">
            <button className={`tool-btn ${state.subtitleTrackId !== null ? "active" : ""}`} onClick={() => setTrackMenu(trackMenu === "sub" ? null : "sub")} disabled={!view.ready} title="Subtitles">
              CC
            </button>
            {trackMenu === "sub" && (
              <TrackMenu kind="sub" tracks={state.tracks} currentId={state.subtitleTrackId}
                onSelect={(id) => selectTrack("sub", id)} onClose={() => setTrackMenu(null)} />
            )}
          </span>
          <button className="tool-btn" onClick={() => runCommand("open_subtitle_dialog")} disabled={state.idle || !view.ready} title="Load subtitle file…">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <rect x="3" y="5" width="18" height="14" rx="2" fill="none" stroke="currentColor" strokeWidth="1.6" />
              <path d="M6 14 H10 M13 14 H18 M6 10.5 H18" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
            </svg>
          </button>

          <span className="menu-anchor">
            <button className={`tool-btn ${videoMenuOpen ? "active" : ""}`} onClick={() => setVideoMenuOpen(!videoMenuOpen)} title="Video settings">
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <rect x="3" y="6" width="18" height="12" rx="1.8" fill="none" stroke="currentColor" strokeWidth="1.6" />
                <path d="M9 21 H15 M12 18 V21" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
              </svg>
            </button>
            {videoMenuOpen && (
              <VideoSettingsMenu
                aspectMode={state.aspectMode}
                rotation={state.rotation}
                hwdec={state.hwdec}
                onSetProperty={setProperty}
                onClose={() => setVideoMenuOpen(false)}
              />
            )}
          </span>
          <span className="menu-anchor">
            <button className={`tool-btn ${eqMenuOpen ? "active" : ""}`} onClick={() => setEqMenuOpen(!eqMenuOpen)} title="Video adjustments">
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M5 4 V20 M12 4 V20 M19 4 V20" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
                <circle cx="5" cy="14" r="2.2" fill="currentColor" />
                <circle cx="12" cy="9" r="2.2" fill="currentColor" />
                <circle cx="19" cy="16" r="2.2" fill="currentColor" />
              </svg>
            </button>
            {eqMenuOpen && (
              <VideoEqMenu
                brightness={state.brightness}
                contrast={state.contrast}
                saturation={state.saturation}
                deinterlace={state.deinterlace}
                onSetProperty={setProperty}
                onClose={() => setEqMenuOpen(false)}
              />
            )}
          </span>

          <div className="volume-control">
            <button className="tool-btn" onClick={toggleMute} title={state.muted ? "Unmute" : "Mute"}>
              {state.muted ? "🔇" : "🔊"}
            </button>
            <div
              className="volume-slider"
              onClick={(e) => {
                const volume = volumeAtClick(e);
                if (volume !== null) void setVolume(volume);
              }}
            >
              <div className="volume-fill" style={{ width: `${(state.volume / 130) * 100}%` }} />
            </div>
          </div>

          <button className="tool-btn" onClick={() => setUrlOpen(true)} title="Open URL…">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M10 14 Q12 12 14 14 T18 14" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
              <path d="M14 10 Q12 12 10 10 T6 10" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
              <path d="M9 15 L6 18 M15 9 L18 6" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
            </svg>
          </button>
          <button
            className={`tool-btn ${state.onTop ? "active" : ""}`}
            onClick={toggleOnTop}
            title="Always on top"
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M14 3 L17 3 L17 6 L14 6 Z" fill="none" stroke="currentColor" strokeWidth="1.6" />
              <path d="M15.5 4.5 H19 V8" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
              <path d="M19 4.5 L12 11.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
              <path d="M5 13 V20 H12" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
              <path d="M9 20 H5 V16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </button>
          <button
            className={`tool-btn ${sidebarOpen && sidebarTab === "playlist" ? "active" : ""}`}
            onClick={() => toggleSidebar("playlist")}
            title="Playlist (v)"
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M4 6 H20 M4 12 H20 M4 18 H14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
            </svg>
          </button>
          <button
            className={`tool-btn ${sidebarOpen && sidebarTab === "chapters" ? "active" : ""}`}
            onClick={() => toggleSidebar("chapters")}
            disabled={state.chapters.length === 0 && state.idle}
            title="Chapters"
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <rect x="3" y="4" width="18" height="16" rx="2" fill="none" stroke="currentColor" strokeWidth="1.6" />
              <path d="M3 9 H21 M8 9 V20 M16 9 V20" stroke="currentColor" strokeWidth="1.6" />
            </svg>
          </button>
          <button
            className="tool-btn about-trigger"
            onClick={() => setAboutOpen(true)}
            aria-label="About BrushLLM Player"
            aria-haspopup="dialog"
            title="About"
          >
            <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
              <circle cx="12" cy="12" r="9" />
              <line x1="12" y1="10.5" x2="12" y2="16" />
              <circle cx="12" cy="7.5" r="0.7" fill="currentColor" stroke="none" />
            </svg>
          </button>
        </div>
      </div>

      {urlOpen && (
        <div
          className="about-overlay"
          onClick={(event) => {
            if (event.target === event.currentTarget) setUrlOpen(false);
          }}
        >
          <section
            id="url-dialog"
            className="about-dialog url-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="url-dialog-title"
          >
            <div className="about-header">
              <h2 id="url-dialog-title">Open URL</h2>
              <button
                className="tool-btn about-close"
                onClick={() => setUrlOpen(false)}
                aria-label="Close URL dialog"
                title="Close"
                autoFocus
              >
                <svg viewBox="0 0 24 24" aria-hidden="true">
                  <line x1="6" y1="6" x2="18" y2="18" />
                  <line x1="18" y1="6" x2="6" y2="18" />
                </svg>
              </button>
            </div>
            <form
              className="url-form"
              onSubmit={(event) => {
                event.preventDefault();
                submitUrl();
              }}
            >
              <input
                className="url-input"
                type="text"
                value={urlInput}
                onChange={(event) => setUrlInput(event.target.value)}
                placeholder="Direct media link or m3u8/HLS address"
                autoFocus
                spellCheck={false}
              />
              <button className="url-submit" type="submit" disabled={urlInput.trim() === ""}>
                Play
              </button>
            </form>
          </section>
        </div>
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
                aria-label="Close About dialog"
                title="Close"
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
