import { useState, useEffect, useRef, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

import { applySnapshot, CommandGate, commandError, initialView, sameMedia, trackFraction, volumeAtClick } from "./player-state";
import type { StateSnapshot } from "./player-state";

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

export default function App() {
  const [view, setView] = useState(initialView);
  const viewRef = useRef(initialView);
  const [invokeError, setInvokeError] = useState<{ generation: number; message: string } | null>(null);
  const [scrubbing, setScrubbing] = useState(false);
  const [scrubPosition, setScrubPosition] = useState(0);
  const trackRef = useRef<HTMLDivElement>(null);
  const dragCleanup = useRef<(() => void) | null>(null);
  const mounted = useRef(false);
  const commandGate = useRef(new CommandGate());
  const state = view.player;

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

  return (
    <div className="app">
      <div className="video-area" onDoubleClick={() => runCommand("send_command", { args: ["cycle", "fullscreen"] })}>
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
            <div className="progress-knob" style={{ left: `${progress * 100}%` }} />
          </div>
          <span className="time-label dim">{formatTime(state.duration)}</span>
        </div>

        <div className="button-row">
          <button className="tool-btn" onClick={() => runCommand("open_file_dialog")} title="Open…">📂</button>
          <button className="tool-btn" onClick={() => runCommand("send_command", { args: ["playlist-prev", "weak"] })} disabled={state.playlistCount < 2 || !view.ready} title="Previous">
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
          <button className="tool-btn" onClick={() => runCommand("send_command", { args: ["playlist-next", "weak"] })} disabled={state.playlistCount < 2 || !view.ready} title="Next">
            ⏭
          </button>
          <button className="tool-btn" onClick={() => runCommand("stop_playback")} disabled={state.idle || !view.ready} title="Stop">
            ⏹
          </button>
          <button className="tool-btn" onClick={() => seekRelative(-5)} title="Back 5s">«</button>
          <button className="tool-btn" onClick={() => seekRelative(5)} title="Forward 5s">»</button>

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
        </div>
      </div>
    </div>
  );
}
