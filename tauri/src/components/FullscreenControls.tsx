import { useState, type ReactNode } from "react";
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
  onSpeedChange: (speed: string) => void;
}

export default function FullscreenControls({
  play, mute, exit, timeline, tools, speed, ready, onSpeedChange,
}: FullscreenControlsProps) {
  const { t } = useI18n();
  const [expanded, setExpanded] = useState(false);
  const label = t("player.options");

  return (
    <div className="fullscreen-controls" data-expanded={expanded}>
      <button type="button" className="playback-tool fullscreen-disclosure"
        aria-label={label} title={label} aria-expanded={expanded}
        aria-controls={expanded ? "fullscreen-playback-tools" : undefined}
        onClick={() => setExpanded((open) => !open)}>
        <PlayerIcon name={expanded ? "chevronLeft" : "chevronRight"} />
        {expanded && label}
      </button>
      <div className="fullscreen-transport">
        {play}
        <PlaybackSpeedPicker speed={speed} disabled={!ready} onChange={onSpeedChange} />
        {mute}
      </div>
      {expanded && (
        <div className="fullscreen-details" id="fullscreen-playback-tools">
          {timeline}
          {tools}
        </div>
      )}
      <div className="fullscreen-exit">{exit}</div>
    </div>
  );
}
