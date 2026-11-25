import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useI18n } from "../i18n";
import PlaybackSpeedPicker from "./PlaybackSpeedPicker";

interface FullscreenControlsProps {
  play: ReactNode;
  mute: ReactNode;
  exit: ReactNode;
  timeline: ReactNode;
  tools: ReactNode;
  speed: number;
  ready: boolean;
  onSpeedChange: (speed: string) => void;
  onError: (error: unknown) => void;
}

export default function FullscreenControls({
  play, mute, exit, timeline, tools, speed, ready, onSpeedChange, onError,
}: FullscreenControlsProps) {
  const { t } = useI18n();
  const label = t("player.options");
  const [visible, setVisible] = useState(false);
  const bar = useRef<HTMLDivElement>(null);
  const pointerInside = useRef(false);
  const dragging = useRef(false);
  const hideTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  const show = useCallback(() => {
    clearTimeout(hideTimer.current);
    pointerInside.current = true;
    setVisible(true);
  }, []);
  const hideAfterLeaving = useCallback(() => {
    clearTimeout(hideTimer.current);
    function dismiss() {
      const element = bar.current;
      if (!element || pointerInside.current || dragging.current || element.querySelector(":focus-visible")) return;
      if (CSS.supports("selector(select:open)") && element.querySelector("select:open")) {
        hideTimer.current = setTimeout(dismiss, 180);
        return;
      }
      setVisible(false);
    }
    hideTimer.current = setTimeout(dismiss, 180);
  }, []);
  const leave = useCallback(() => {
    pointerInside.current = false;
    hideAfterLeaving();
  }, [hideAfterLeaving]);

  useEffect(() => () => clearTimeout(hideTimer.current), []);
  useEffect(() => {
    if (!isTauri()) return;
    let mounted = true;
    const subscription = listen<boolean>("video-controls-hover", ({ payload }) => {
      if (mounted) (payload ? show : leave)();
    });
    void subscription.catch((error) => { if (mounted) onError(error); });
    return () => {
      mounted = false;
      void subscription.then((stop) => stop()).catch(() => {});
    };
  }, [leave, onError, show]);

  if (!visible) {
    return (
      <button type="button" className="playback-tool fullscreen-reveal"
        onPointerEnter={(event) => { if (event.pointerType === "mouse") show(); }}
        onClick={show}>{label}</button>
    );
  }

  return (
    <div ref={bar} className="fullscreen-controls" role="group" aria-label={label}
      onPointerEnter={(event) => { if (event.pointerType === "mouse") show(); }}
      onPointerLeave={(event) => { if (event.pointerType === "mouse") leave(); }}
      onGotPointerCapture={() => { dragging.current = true; }}
      onLostPointerCapture={() => { dragging.current = false; hideAfterLeaving(); }}
      onBlur={(event) => { if (!event.currentTarget.contains(event.relatedTarget)) hideAfterLeaving(); }}>
      <div className="fullscreen-transport">
        {play}
        {timeline}
        <PlaybackSpeedPicker speed={speed} disabled={!ready} onChange={onSpeedChange} />
        {mute}
        {exit}
      </div>
      <div className="fullscreen-details">
        {tools}
      </div>
    </div>
  );
}
