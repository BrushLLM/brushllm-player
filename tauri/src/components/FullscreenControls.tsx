import type { ReactNode } from "react";
import { useI18n } from "../i18n";
import PlaybackSpeedPicker from "./PlaybackSpeedPicker";
import PlayerIcon from "./PlayerIcon";

interface FullscreenControlsProps {
  play: ReactNode;
  mute: ReactNode;
  exit: ReactNode;
  timeline: ReactNode;
  tools: ReactNode;
  speed: number;
  ready: boolean;
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
  onSpeedChange: (speed: string) => void;
}

export default function FullscreenControls({
  play, mute, exit, timeline, tools, speed, ready, expanded, onExpandedChange, onSpeedChange,
}: FullscreenControlsProps) {
  const { t } = useI18n();
  const label = t("player.options");
  const toggleLabel = expanded ? t("player.sidebar-collapse") : label;

  return (
    <div className="fullscreen-controls" data-expanded={expanded}>
      <button type="button" className="playback-tool fullscreen-disclosure"
        aria-label={toggleLabel} title={toggleLabel} aria-expanded={expanded}
        aria-controls={expanded ? "fullscreen-playback-tools" : undefined}
        onPointerEnter={(event) => {
          if (!expanded && event.pointerType === "mouse") onExpandedChange(true);
        }}
        onClick={() => onExpandedChange(!expanded)}>
        <PlayerIcon name={expanded ? "chevronLeft" : "chevronRight"} />
        {expanded && label}
      </button>
      {expanded && (
        <>
          <div className="fullscreen-transport">
            {play}
            <PlaybackSpeedPicker speed={speed} disabled={!ready} onChange={onSpeedChange} />
            {mute}
          </div>
          <div className="fullscreen-details" id="fullscreen-playback-tools">
            {timeline}
            {tools}
          </div>
          <div className="fullscreen-exit">{exit}</div>
        </>
      )}
    </div>
  );
}
