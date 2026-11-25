import { useLayoutEffect, useRef, useState } from "react";
import type { PlayerState } from "../player-state";
import { useI18n } from "../i18n";
import PlayerIcon from "./PlayerIcon";
import TrackMenu from "./TrackMenu";
import VideoSettingsMenu from "./VideoSettingsMenu";
import VideoEqMenu from "./VideoEqMenu";

interface PlaybackOptionsProps {
  state: PlayerState;
  ready: boolean;
  onCommand: (command: string, args?: Record<string, unknown>) => void;
  onShowChapters: () => void;
  onToggleOnTop: () => void;
  onClose: () => void;
}

export default function PlaybackOptions({
  state, ready, onCommand, onShowChapters, onToggleOnTop, onClose,
}: PlaybackOptionsProps) {
  const { t } = useI18n();
  const [section, setSection] = useState<"options" | "audio" | "sub" | "video" | "equalizer">("options");
  const panel = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    panel.current?.querySelector<HTMLElement>("button:not([disabled]), select:not([disabled])")?.focus();
  }, [section]);

  const setProperty = (name: string, value: string) => onCommand("set_property", { name, value });
  const sendMpv = (...args: (string | number)[]) => onCommand("send_command", { args });
  const active = ready && !state.idle;

  return (
    <section ref={panel} className="playback-options" id="playback-options" aria-label={t("player.options")}>
      {section !== "options" && (
        <button className="tool-btn options-back" type="button" title={t("player.options")}
          aria-label={t("player.options")} onClick={() => setSection("options")}>
          <PlayerIcon name="back" />
        </button>
      )}
      {section === "options" && (
        <div className="options-grid">
          <label className="options-speed">
            <span>{t("controls.speed")}</span>
            <select disabled={!ready} value={state.speed} onChange={(event) => setProperty("speed", event.target.value)}>
              {[...new Set([0.5, 0.75, 1, 1.25, 1.5, 2, state.speed])].sort((a, b) => a - b)
                .map((speed) => <option key={speed} value={speed}>{Number(speed.toFixed(2))}×</option>)}
            </select>
          </label>
          <button type="button" onClick={onShowChapters}>{t("panel.chapters")}</button>
          <div className="options-divider" />
          <button type="button" disabled={!ready} onClick={() => setSection("audio")}>{t("panel.tracks.audio")}</button>
          <button type="button" disabled={!ready} onClick={() => setSection("sub")}>{t("panel.tracks.subtitle")}</button>
          <button type="button" disabled={!active} onClick={() => onCommand("open_subtitle_dialog")}>{t("menu.load-subtitle")}</button>
          <button type="button" disabled={!ready} onClick={() => setSection("video")}>{t("controls.video-settings")}</button>
          <button type="button" disabled={!ready} onClick={() => setSection("equalizer")}>{t("controls.equalizer")}</button>
          <div className="options-divider" />
          <details className="options-advanced">
            <summary>{t("player.advanced-controls")}</summary>
            <div className="options-grid">
              <button type="button" disabled={!active} onClick={() => onCommand("screenshot")}>{t("menu.screenshot")}</button>
              <button type="button" disabled={!active} aria-pressed={state.abLoopA !== null || state.abLoopB !== null}
                onClick={() => sendMpv("ab-loop")}>{t("menu.ab-loop")}</button>
              <button type="button" disabled={!active} onClick={() => onCommand("seek_relative", { seconds: -5 })}>{t("menu.step-backward")}</button>
              <button type="button" disabled={!active} onClick={() => onCommand("seek_relative", { seconds: 5 })}>{t("menu.step-forward")}</button>
              <button type="button" disabled={!active || !state.paused} onClick={() => sendMpv("frame-back-step")}>{t("menu.frame-back-step")}</button>
              <button type="button" disabled={!active} onClick={() => sendMpv("frame-step")}>{t("menu.frame-step")}</button>
              <button type="button" aria-pressed={state.onTop} onClick={onToggleOnTop}>{t("video.ontop")}</button>
            </div>
          </details>
        </div>
      )}
      {(section === "audio" || section === "sub") && (
        <TrackMenu kind={section} tracks={state.tracks}
          currentId={section === "audio" ? state.audioTrackId : state.subtitleTrackId}
          onSelect={(id) => setProperty(section === "audio" ? "aid" : "sid", id === null ? "no" : String(id))}
          onClose={onClose} />
      )}
      {section === "video" && (
        <VideoSettingsMenu aspectMode={state.aspectMode} rotation={state.rotation}
          hwdec={state.hwdec} onSetProperty={setProperty} />
      )}
      {section === "equalizer" && (
        <VideoEqMenu brightness={state.brightness} contrast={state.contrast}
          saturation={state.saturation} deinterlace={state.deinterlace}
          onSetProperty={setProperty} />
      )}
    </section>
  );
}
