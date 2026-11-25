import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import type { PlayerState } from "../player-state";
import { useI18n } from "../i18n";
import PlayerIcon from "./PlayerIcon";
import type { PlayerIconName } from "./PlayerIcon";
import PlaybackSpeedPicker from "./PlaybackSpeedPicker";
import ChaptersPanel from "./ChaptersPanel";
import TrackMenu from "./TrackMenu";
import VideoSettingsMenu from "./VideoSettingsMenu";
import VideoEqMenu from "./VideoEqMenu";
import SubtitleAutoLoadControl from "./SubtitleAutoLoadControl";
import type { SubtitleAutoLoadProps } from "./SubtitleAutoLoadControl";

interface PlaybackOptionsProps {
  state: PlayerState;
  ready: boolean;
  modalOpen: boolean;
  fullscreen: boolean;
  subtitleAutoLoad: SubtitleAutoLoadProps;
  onCommand: (command: string, args?: Record<string, unknown>) => void;
  onShowChapters: () => void;
  onSelectChapter: (index: number) => void;
  onToggleOnTop: () => void;
}

const panels = [
  { id: "speed", title: "controls.speed", icon: "speed" },
  { id: "audio", title: "panel.tracks.audio", icon: "volume" },
  { id: "sub", title: "panel.tracks.subtitle", icon: "captions" },
  { id: "video", title: "controls.video-settings", icon: "adjustments" },
  { id: "equalizer", title: "controls.equalizer", icon: "equalizer" },
  { id: "chapters", title: "panel.chapters", icon: "playlist" },
] as const satisfies ReadonlyArray<{ id: string; title: string; icon: PlayerIconName }>;

export default function PlaybackOptions({
  state, ready, modalOpen, fullscreen, subtitleAutoLoad, onCommand, onShowChapters, onSelectChapter, onToggleOnTop,
}: PlaybackOptionsProps) {
  const { t } = useI18n();
  const [section, setSection] = useState<typeof panels[number] | null>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const firstPanelButton = useRef<HTMLButtonElement>(null);

  useLayoutEffect(() => {
    if (section && !modalOpen) firstPanelButton.current?.focus();
  }, [section, modalOpen]);

  const closePanel = useCallback(() => {
    setSection(null);
    trigger.current?.focus();
  }, []);

  useEffect(() => {
    if (!section || modalOpen) return;
    const onEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      closePanel();
    };
    window.addEventListener("keydown", onEscape, true);
    return () => window.removeEventListener("keydown", onEscape, true);
  }, [closePanel, modalOpen, section]);

  const setProperty = (name: string, value: string) => onCommand("set_property", { name, value });
  const sendMpv = (...args: (string | number)[]) => onCommand("send_command", { args });
  const active = ready && !state.idle;

  function action(icon: PlayerIconName, title: string, onClick: () => void, disabled = false,
                  pressed?: boolean, iconOnly = false): ReactNode {
    return (
      <button className="playback-tool" type="button" disabled={disabled}
        aria-label={title} title={title} aria-pressed={pressed} onClick={onClick}>
        <PlayerIcon name={icon} />
        {!iconOnly && <span>{title}</span>}
      </button>
    );
  }

  return (
    <>
      <div className="playback-tools" role="group" aria-label={t("player.options")}>
        {panels.filter(({ id }) => fullscreen ? id !== "speed" : id !== "chapters").map((option) => (
          <button key={option.id} type="button" className="playback-tool"
            disabled={!ready && option.id !== "sub" && option.id !== "chapters"}
            aria-expanded={section === option}
            aria-controls={section === option ? "playback-options" : undefined}
            onClick={(event) => {
              if (section === option) closePanel();
              else {
                trigger.current = event.currentTarget;
                setSection(option);
              }
            }}>
            <PlayerIcon name={option.icon} />
            <span>{t(option.title)}</span>
          </button>
        ))}
        {!fullscreen && action("playlist", t("panel.chapters"), onShowChapters)}
        {action("camera", t("menu.screenshot"), () => onCommand("screenshot"), !active)}
        {action("repeat", t("menu.ab-loop"), () => sendMpv("ab-loop"), !active,
          state.abLoopA !== null || state.abLoopB !== null)}
        {action("pin", t("video.ontop"), onToggleOnTop, false, state.onTop)}
        <div className="step-tools">
          {action("seekBack", t("menu.step-backward"), () => onCommand("seek_relative", { seconds: -5 }), !active, undefined, true)}
          {action("seekForward", t("menu.step-forward"), () => onCommand("seek_relative", { seconds: 5 }), !active, undefined, true)}
          {action("previous", t("menu.frame-back-step"), () => sendMpv("frame-back-step"), !active || !state.paused, undefined, true)}
          {action("next", t("menu.frame-step"), () => sendMpv("frame-step"), !active, undefined, true)}
        </div>
      </div>
      {section && (
        <section className="playback-options" id="playback-options" aria-labelledby="playback-options-title">
          <header className="playback-options-header">
            <h2 id="playback-options-title">{t(section.title)}</h2>
            <button ref={firstPanelButton} className="tool-btn" type="button"
              onClick={closePanel} aria-label={t("panel.cancel")} title={t("panel.cancel")}>
              <PlayerIcon name="close" />
            </button>
          </header>
          {section.id === "speed" && (
            <PlaybackSpeedPicker speed={state.speed} disabled={!ready}
              onChange={(speed) => setProperty("speed", speed)} />
          )}
          {(section.id === "audio" || section.id === "sub") && (
            <>
              {active && (
                <TrackMenu kind={section.id} tracks={state.tracks}
                  currentId={section.id === "audio" ? state.audioTrackId : state.subtitleTrackId}
                  onSelect={(id) => setProperty(section.id === "audio" ? "aid" : "sid", id === null ? "no" : String(id))}
                  onClose={closePanel} />
              )}
              {section.id === "sub" && (
                <div className="subtitle-options">
                  <SubtitleAutoLoadControl {...subtitleAutoLoad} />
                  <button type="button" className="playback-tool" disabled={!active}
                    onClick={() => onCommand("open_subtitle_dialog")}>
                    <PlayerIcon name="folder" />
                    {t("menu.load-subtitle")}
                  </button>
                </div>
              )}
            </>
          )}
          {section.id === "video" && (
            <VideoSettingsMenu aspectMode={state.aspectMode} rotation={state.rotation}
              hwdec={state.hwdec} onSetProperty={setProperty} />
          )}
          {section.id === "equalizer" && (
            <VideoEqMenu brightness={state.brightness} contrast={state.contrast}
              saturation={state.saturation} deinterlace={state.deinterlace}
              onSetProperty={setProperty} />
          )}
          {section.id === "chapters" && (
            <ChaptersPanel chapters={state.chapters} currentChapter={state.currentChapter}
              onSelect={onSelectChapter} showTitle={false} />
          )}
        </section>
      )}
    </>
  );
}
