import { useRef, useState, type PointerEvent } from "react";
import { useI18n } from "../i18n";
import { formatClock } from "../library-state";
import { sliderValueAtKey, trackFraction } from "../player-state";

interface Props {
  position: number;
  duration: number;
  abLoopA: number | null;
  abLoopB: number | null;
  canSeek: boolean;
  showTimeHint: boolean;
  onSeek: (position: number) => void;
}

function fractionAtPointer(event: PointerEvent<HTMLDivElement>) {
  const rect = event.currentTarget.getBoundingClientRect();
  return trackFraction(event.clientX, rect.left, rect.width);
}

export default function PlaybackTimeline({ position, duration, abLoopA, abLoopB, canSeek, showTimeHint, onSeek }: Props) {
  const { t } = useI18n();
  const [scrubPosition, setScrubPosition] = useState<number | null>(null);
  const [hoverFraction, setHoverFraction] = useState<number | null>(null);
  const dragging = useRef<number | null>(null);
  const current = Math.min(scrubPosition ?? position, duration);
  const progress = duration > 0 ? current / duration : 0;
  const elapsedLabel = formatClock(current);
  const durationLabel = formatClock(duration);

  const endDrag = () => {
    dragging.current = null;
    setScrubPosition(null);
  };

  return (
    <div className="progress-row">
      <span className="time-label">{elapsedLabel}</span>
      <div className="progress-track" role="slider" tabIndex={canSeek ? 0 : -1}
        aria-label={t("controls.progress")} aria-valuemin={0} aria-valuemax={duration}
        aria-valuenow={current} aria-valuetext={elapsedLabel + " / " + durationLabel}
        aria-disabled={!canSeek}
        onPointerDown={(event) => {
          if (!canSeek || event.button !== 0 || dragging.current !== null) return;
          const fraction = fractionAtPointer(event);
          if (fraction === null) return;
          dragging.current = event.pointerId;
          event.currentTarget.setPointerCapture(event.pointerId);
          setScrubPosition(fraction * duration);
        }}
        onPointerMove={(event) => {
          const isDragging = dragging.current === event.pointerId;
          const isHovering = showTimeHint && event.pointerType === "mouse";
          if (!canSeek || (!isDragging && !isHovering)) return;
          const fraction = fractionAtPointer(event);
          if (isDragging && fraction !== null) setScrubPosition(fraction * duration);
          if (isHovering) setHoverFraction(fraction);
        }}
        onPointerLeave={() => setHoverFraction(null)}
        onPointerUp={(event) => {
          if (dragging.current !== event.pointerId) return;
          const fraction = fractionAtPointer(event);
          endDrag();
          if (canSeek && fraction !== null) onSeek(fraction * duration);
        }}
        onLostPointerCapture={(event) => {
          if (dragging.current === event.pointerId) endDrag();
        }}
        onKeyDown={(event) => {
          if (event.ctrlKey || event.metaKey || event.altKey || !canSeek) return;
          const position = sliderValueAtKey(event.key, current, 0, duration, 5);
          if (position === null) return;
          event.preventDefault();
          event.stopPropagation();
          onSeek(position);
        }}>
        <div className="progress-bg">
          <div className="progress-fill" style={{ width: progress * 100 + "%" }} />
        </div>
        {duration > 0 && abLoopA !== null && (
          <div className="ab-marker" style={{ left: abLoopA / duration * 100 + "%" }} title="A" />
        )}
        {duration > 0 && abLoopB !== null && (
          <div className="ab-marker" style={{ left: abLoopB / duration * 100 + "%" }} title="B" />
        )}
        <div className="progress-knob" style={{ left: progress * 100 + "%" }} hidden={!canSeek} />
        {canSeek && showTimeHint && hoverFraction !== null && (
          <span className="seek-time-hint" aria-hidden="true"
            style={{ left: `clamp(32px, ${hoverFraction * 100}%, 100% - 32px)` }}>
            {formatClock(hoverFraction * duration)}
          </span>
        )}
      </div>
      <span className="time-label dim">{durationLabel}</span>
    </div>
  );
}
