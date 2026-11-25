import { useI18n } from "../i18n";

interface PlaybackSpeedPickerProps {
  speed: number;
  disabled: boolean;
  onChange: (speed: string) => void;
}

export default function PlaybackSpeedPicker({ speed, disabled, onChange }: PlaybackSpeedPickerProps) {
  const { t } = useI18n();
  const label = t("controls.speed");
  const rates = [...new Set([0.5, 0.75, 1, 1.25, 1.5, 2, speed])].sort((a, b) => a - b);

  return (
    <select className="playback-speed-picker" aria-label={label} title={label}
      disabled={disabled} value={speed} onChange={(event) => onChange(event.target.value)}>
      {rates.map((rate) => <option key={rate} value={rate}>{Number(rate.toFixed(2))}×</option>)}
    </select>
  );
}
