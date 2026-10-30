// Video equalizer popup modeled on IINA's QuickSettingViewController eq
// section: brightness / contrast / saturation sliders (-100..100, mpv
// properties of the same name) plus a deinterlace yes/no toggle. All values
// go through the set_property backend command.

import { useEffect, useRef } from "react";

export interface VideoEqMenuProps {
  /** Current mpv brightness value (-100..100). */
  brightness: number;
  /** Current mpv contrast value (-100..100). */
  contrast: number;
  /** Current mpv saturation value (-100..100). */
  saturation: number;
  /** Current mpv deinterlace flag (true = yes). */
  deinterlace: boolean;
  /** Dispatches a set_property command: (name, value). */
  onSetProperty: (name: string, value: string) => void;
  /** Called when the menu wants to close (Escape key or outside click). */
  onClose?: () => void;
}

interface EqSliderConfig {
  label: string;
  property: string;
  value: number;
}

export default function VideoEqMenu({
  brightness,
  contrast,
  saturation,
  deinterlace,
  onSetProperty,
  onClose,
}: VideoEqMenuProps) {
  const rootRef = useRef<HTMLDivElement>(null);

  // Close on Escape and on clicks outside the popup (capture phase so the
  // opening trigger button also counts as "outside").
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

  const sliders: EqSliderConfig[] = [
    { label: "Brightness", property: "brightness", value: brightness },
    { label: "Contrast", property: "contrast", value: contrast },
    { label: "Saturation", property: "saturation", value: saturation },
  ];

  const resetAll = () => {
    onSetProperty("brightness", "0");
    onSetProperty("contrast", "0");
    onSetProperty("saturation", "0");
  };

  return (
    <div ref={rootRef} className="veq-menu" role="menu" aria-label="Video equalizer">
      <div className="vsm-section-title">Video Equalizer</div>
      {sliders.map((slider) => (
        <div key={slider.property} className="veq-slider-row">
          <label className="veq-slider-label" htmlFor={`veq-${slider.property}`}>
            {slider.label}
          </label>
          <input
            id={`veq-${slider.property}`}
            className="veq-slider"
            type="range"
            min={-100}
            max={100}
            step={1}
            value={slider.value}
            aria-valuetext={String(slider.value)}
            onChange={(event) => onSetProperty(slider.property, event.target.value)}
          />
          <span className="veq-slider-value">{slider.value}</span>
        </div>
      ))}

      <div className="vsm-divider" />

      <button
        type="button"
        className={`vsm-toggle ${deinterlace ? "active" : ""}`}
        role="menuitemcheckbox"
        aria-checked={deinterlace}
        onClick={() => onSetProperty("deinterlace", deinterlace ? "no" : "yes")}
      >
        <span className="vsm-toggle-label">Deinterlace</span>
        <span className={`vsm-switch ${deinterlace ? "on" : ""}`} aria-hidden="true">
          <span className="vsm-switch-knob" />
        </span>
      </button>

      <button type="button" className="veq-reset" onClick={resetAll}>
        Reset
      </button>
    </div>
  );
}
