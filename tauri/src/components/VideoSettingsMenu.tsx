// Video settings popup modeled on IINA's SidebarVideoPane: aspect ratio
// (video-aspect-override), rotation (video-rotate) and hardware decoding
// (hwdec). Every value goes through the set_property backend command.

import { useEffect, useRef } from "react";

export interface VideoSettingsMenuProps {
  /** Current video-aspect-override value; "-1" means container default. */
  aspectMode: string;
  /** Current video-rotate value in degrees (0/90/180/270). */
  rotation: number;
  /** Current hwdec value ("auto-safe" = enabled, "no" = disabled). */
  hwdec: string;
  /** Dispatches a set_property command: (name, value). */
  onSetProperty: (name: string, value: string) => void;
  /** Called when the menu wants to close (Escape key or outside click). */
  onClose?: () => void;
}

const ASPECT_OPTIONS: { label: string; value: string }[] = [
  { label: "Default", value: "-1" },
  { label: "4:3", value: "4:3" },
  { label: "16:9", value: "16:9" },
  { label: "2.35:1", value: "2.35:1" },
  { label: "1:1", value: "1:1" },
];

const ROTATION_OPTIONS = [0, 90, 180, 270];

export default function VideoSettingsMenu({
  aspectMode,
  rotation,
  hwdec,
  onSetProperty,
  onClose,
}: VideoSettingsMenuProps) {
  const rootRef = useRef<HTMLDivElement>(null);

  // Close on Escape and on clicks outside the popup. The listener is
  // registered with capture so it fires even if the click lands on the
  // trigger button that opened this menu.
  useEffect(() => {
    if (!onClose) return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onClose();
      }
    };
    const handlePointerDown = (event: MouseEvent | TouchEvent) => {
      const root = rootRef.current;
      if (root && event.target instanceof Node && !root.contains(event.target)) {
        onClose();
      }
    };
    document.addEventListener("keydown", handleKeyDown, true);
    document.addEventListener("mousedown", handlePointerDown, true);
    return () => {
      document.removeEventListener("keydown", handleKeyDown, true);
      document.removeEventListener("mousedown", handlePointerDown, true);
    };
  }, [onClose]);

  const hwdecEnabled = hwdec !== "no" && hwdec !== "";

  return (
    <div ref={rootRef} className="vsm-menu" role="menu" aria-label="Video settings">
      <div className="vsm-section-title">Aspect Ratio</div>
      <div className="vsm-option-row" role="group" aria-label="Aspect ratio">
        {ASPECT_OPTIONS.map((option) => (
          <button
            key={option.value}
            type="button"
            className={`vsm-option ${aspectMode === option.value ? "active" : ""}`}
            role="menuitemradio"
            aria-checked={aspectMode === option.value}
            onClick={() => onSetProperty("video-aspect-override", option.value)}
          >
            {option.label}
          </button>
        ))}
      </div>

      <div className="vsm-section-title">Rotation</div>
      <div className="vsm-option-row" role="group" aria-label="Rotation">
        {ROTATION_OPTIONS.map((value) => (
          <button
            key={value}
            type="button"
            className={`vsm-option ${rotation === value ? "active" : ""}`}
            role="menuitemradio"
            aria-checked={rotation === value}
            onClick={() => onSetProperty("video-rotate", String(value))}
          >
            {value === 0 ? "0°" : `${value}°`}
          </button>
        ))}
      </div>

      <div className="vsm-divider" />

      <button
        type="button"
        className={`vsm-toggle ${hwdecEnabled ? "active" : ""}`}
        role="menuitemcheckbox"
        aria-checked={hwdecEnabled}
        onClick={() => onSetProperty("hwdec", hwdecEnabled ? "no" : "auto-safe")}
      >
        <span className="vsm-toggle-label">Hardware Decoding</span>
        <span className={`vsm-switch ${hwdecEnabled ? "on" : ""}`} aria-hidden="true">
          <span className="vsm-switch-knob" />
        </span>
      </button>
    </div>
  );
}
