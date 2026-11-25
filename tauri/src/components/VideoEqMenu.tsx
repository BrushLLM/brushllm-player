// Video equalizer popup modeled on IINA's QuickSettingViewController eq
// section: brightness / contrast / saturation sliders (-100..100, mpv
// properties of the same name) plus a deinterlace yes/no toggle. All values
// go through the set_property backend command.

import { useI18n } from "../i18n";

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
}: VideoEqMenuProps) {
  const { t } = useI18n();

  const sliders: EqSliderConfig[] = [
    { label: t("video.brightness"), property: "brightness", value: brightness },
    { label: t("video.contrast"), property: "contrast", value: contrast },
    { label: t("video.saturation"), property: "saturation", value: saturation },
  ];

  const resetAll = () => {
    onSetProperty("brightness", "0");
    onSetProperty("contrast", "0");
    onSetProperty("saturation", "0");
  };

  return (
    <div className="veq-menu" role="group" aria-label={t("controls.equalizer")}>
      <div className="vsm-section-title">{t("controls.equalizer")}</div>
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
        aria-pressed={deinterlace}
        onClick={() => onSetProperty("deinterlace", deinterlace ? "no" : "yes")}
      >
        <span className="vsm-toggle-label">{t("video.deinterlace")}</span>
        <span className={`vsm-switch ${deinterlace ? "on" : ""}`} aria-hidden="true">
          <span className="vsm-switch-knob" />
        </span>
      </button>

      <button type="button" className="veq-reset" onClick={resetAll}>
        {t("video.delay-reset")}
      </button>
    </div>
  );
}
