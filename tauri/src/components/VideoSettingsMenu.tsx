// Video settings popup modeled on IINA's SidebarVideoPane: aspect ratio
// (video-aspect-override), rotation (video-rotate) and hardware decoding
// (hwdec). Every value goes through the set_property backend command.

import { useI18n } from "../i18n";

export interface VideoSettingsMenuProps {
  /** Current video-aspect-override value; "-1" means container default. */
  aspectMode: string;
  /** Current video-rotate value in degrees (0/90/180/270). */
  rotation: number;
  /** Current hwdec value ("auto-safe" = enabled, "no" = disabled). */
  hwdec: string;
  /** Dispatches a set_property command: (name, value). */
  onSetProperty: (name: string, value: string) => void;
}

const ASPECT_OPTIONS: { label: string; value: string }[] = [
  { label: "video.aspect.fit", value: "-1" },
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
}: VideoSettingsMenuProps) {
  const { t } = useI18n();

  const hwdecEnabled = hwdec !== "no" && hwdec !== "";

  return (
    <div className="vsm-menu" role="group" aria-label={t("controls.video-settings")}>
      <div className="vsm-section-title">{t("video.aspect")}</div>
      <div className="vsm-option-row" role="group" aria-label={t("video.aspect")}>
        {ASPECT_OPTIONS.map((option) => (
          <button
            key={option.value}
            type="button"
            className={`vsm-option ${aspectMode === option.value ? "active" : ""}`}
            aria-pressed={aspectMode === option.value}
            onClick={() => onSetProperty("video-aspect-override", option.value)}
          >
            {option.value === "-1" ? t(option.label) : option.label}
          </button>
        ))}
      </div>

      <div className="vsm-section-title">{t("video.rotate")}</div>
      <div className="vsm-option-row" role="group" aria-label={t("video.rotate")}>
        {ROTATION_OPTIONS.map((value) => (
          <button
            key={value}
            type="button"
            className={`vsm-option ${rotation === value ? "active" : ""}`}
            aria-pressed={rotation === value}
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
        aria-pressed={hwdecEnabled}
        onClick={() => onSetProperty("hwdec", hwdecEnabled ? "no" : "auto-safe")}
      >
        <span className="vsm-toggle-label">{t("video.hwdec")}</span>
        <span className={`vsm-switch ${hwdecEnabled ? "on" : ""}`} aria-hidden="true">
          <span className="vsm-switch-knob" />
        </span>
      </button>
    </div>
  );
}
