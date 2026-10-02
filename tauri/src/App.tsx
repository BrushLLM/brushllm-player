import { useState, useEffect, useRef, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

interface PlayerState {
  paused: boolean;
  position: number;
  duration: number;
  idle: boolean;
  mediaTitle: string;
  fileName: string;
  volume: number;
  muted: boolean;
  speed: number;
  playlistCount: number;
  playlistPos: number;
}

const initialState: PlayerState = {
  paused: true,
  position: 0,
  duration: 0,
  idle: true,
  mediaTitle: "",
  fileName: "",
  volume: 100,
  muted: false,
  speed: 1,
  playlistCount: 0,
  playlistPos: -1,
};

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
  const [state, setState] = useState<PlayerState>(initialState);
  const [scrubbing, setScrubbing] = useState(false);
  const [scrubPosition, setScrubPosition] = useState(0);
  const trackRef = useRef<HTMLDivElement>(null);

  // Listen for mpv property changes
  useEffect(() => {
    const unlisten = listen<{ name: string; value: unknown }>("mpv-property", (event) => {
      const { name, value } = event.payload;
      setState((prev) => {
        const next = { ...prev };
        switch (name) {
          case "pause": next.paused = value as boolean; break;
          case "time-pos": if (!scrubbingRef.current) next.position = Math.max(value as number, 0); break;
          case "duration": next.duration = Math.max(value as number, 0); break;
          case "idle-active": next.idle = value as boolean; break;
          case "media-title": next.mediaTitle = (value as string) || ""; break;
          case "filename": next.fileName = (value as string) || ""; break;
          case "volume": next.volume = value as number; break;
          case "mute": next.muted = value as boolean; break;
          case "speed": next.speed = value as number; break;
          case "playlist-count": next.playlistCount = value as number; break;
          case "playlist-pos": next.playlistPos = value as number; break;
        }
        return next;
      });
    });
    return () => { unlisten.then((fn) => fn()); };
  }, []);

  const scrubbingRef = useRef(false);
  useEffect(() => { scrubbingRef.current = scrubbing; }, [scrubbing]);

  const effectivePosition = scrubbing ? scrubPosition : state.position;
  const progress = state.duration > 0 ? Math.min(effectivePosition / state.duration, 1) : 0;

  // Progress bar scrubbing
  const handleTrackClick = useCallback((e: React.MouseEvent) => {
    if (!trackRef.current || state.duration <= 0) return;
    const rect = trackRef.current.getBoundingClientRect();
    const fraction = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1);
    invoke("seek", { position: fraction * state.duration });
  }, [state.duration]);

  const handleTrackMouseDown = useCallback((e: React.MouseEvent) => {
    if (!trackRef.current || state.duration <= 0) return;
    setScrubbing(true);
    const rect = trackRef.current.getBoundingClientRect();
    const fraction = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1);
    setScrubPosition(fraction * state.duration);

    const onMouseMove = (e: MouseEvent) => {
      const fraction = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1);
      setScrubPosition(fraction * state.duration);
    };
    const onMouseUp = (e: MouseEvent) => {
      const fraction = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1);
      setScrubbing(false);
      invoke("seek", { position: fraction * state.duration });
      window.removeEventListener("mousemove", onMouseMove);
      window.removeEventListener("mouseup", onMouseUp);
    };
    window.addEventListener("mousemove", onMouseMove);
    window.addEventListener("mouseup", onMouseUp);
  }, [state.duration]);

  const togglePlay = () => invoke("toggle_pause");
  const seekRelative = (s: number) => invoke("seek_relative", { seconds: s });
  const setVolume = (v: number) => invoke("set_property", { name: "volume", value: String(v) });
  const setSpeed = (s: number) => invoke("set_property", { name: "speed", value: String(s) });
  const toggleMute = () => invoke("set_property", { name: "mute", value: state.muted ? "no" : "yes" });

  return (
    <div className="app">
      <div className="video-area" onDoubleClick={() => invoke("send_command", { args: ["cycle", "fullscreen"] })}>
        {state.idle && (
          <div className="empty-state" onClick={() => invoke("open_file_dialog")} style={{ cursor: "pointer" }}>
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
            onClick={handleTrackClick}
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
          <button className="tool-btn" onClick={() => invoke("open_file_dialog")} title="Open…">📂</button>
          <button className="tool-btn" onClick={() => invoke("send_command", { args: ["playlist-prev", "weak"] })} disabled={state.playlistCount < 2} title="Previous">
            ⏮
          </button>
          <button
            className={`play-btn ${!state.paused ? "playing" : ""}`}
            onClick={togglePlay}
            disabled={state.idle}
            title={state.paused ? "Play" : "Pause"}
          >
            {state.paused ? "▶" : "⏸"}
          </button>
          <button className="tool-btn" onClick={() => invoke("send_command", { args: ["playlist-next", "weak"] })} disabled={state.playlistCount < 2} title="Next">
            ⏭
          </button>
          <button className="tool-btn" onClick={() => invoke("stop_playback")} disabled={state.idle} title="Stop">
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
                const rect = (e.target as HTMLElement).getBoundingClientRect();
                const fraction = (e.clientX - rect.left) / rect.width;
                setVolume(Math.round(fraction * 130));
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
