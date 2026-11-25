import { useI18n } from "../i18n";

const modes = {
  off: "panel.tracks.off",
  matching: "subtitle.auto-load-matching",
  folder: "subtitle.auto-load-folder",
} as const;

export type SubtitleAutoLoad = keyof typeof modes;
const storageKey = "brushplayer.subtitleAutoLoad";

export function readSubtitleAutoLoad(): SubtitleAutoLoad {
  const mode = localStorage.getItem(storageKey);
  return mode === "off" || mode === "folder" ? mode : "matching";
}

export function rememberSubtitleAutoLoad(mode: SubtitleAutoLoad) {
  localStorage.setItem(storageKey, mode);
}

export interface SubtitleAutoLoadProps {
  mode: SubtitleAutoLoad;
  pending: boolean;
  onChange: (mode: SubtitleAutoLoad) => void;
}

export default function SubtitleAutoLoadControl({ mode, pending, onChange }: SubtitleAutoLoadProps) {
  const { t } = useI18n();
  return (
    <label className="subtitle-auto-load">
      <span>{t("subtitle.auto-load")}</span>
      <select value={mode} disabled={pending} onChange={(event) => onChange(event.target.value as SubtitleAutoLoad)}>
        {Object.entries(modes).map(([value, title]) => (
          <option key={value} value={value}>{t(title)}</option>
        ))}
      </select>
      <small>{t("subtitle.auto-load-hint")}</small>
    </label>
  );
}
