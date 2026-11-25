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

  return (
    <div className="fullscreen-controls" data-expanded={expanded}>
      <button type="button" className="playback-tool fullscreen-disclosure"
        aria-label={label} title={label} aria-expanded={expanded}
        aria-controls={expanded ? "fullscreen-playback-tools" : undefined}
        onPointerEnter={(event) => {
          if (!expanded && event.pointerType === "mouse") onExpandedChange(true);
        }}
        onClick={() => onExpandedChange(!expanded)}>
        <PlayerIcon name={expanded ? "chevronDown" : "chevronUp"} />
      </button>
      {expanded && (
        <>
          <div className="fullscreen-transport">
            {play}
            {timeline}
            <PlaybackSpeedPicker speed={speed} disabled={!ready} onChange={onSpeedChange} />
            {mute}
            {exit}
          </div>
          <div className="fullscreen-details" id="fullscreen-playback-tools">
            {tools}
          </div>
        </>
      )}
    </div>
  );
}
