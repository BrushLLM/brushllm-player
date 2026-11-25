import { useI18n } from "../i18n";
import { formatPlaybackRate, playbackRates } from "../playback-speed";

interface PlaybackSpeedPickerProps {
  speed: number;
  disabled: boolean;
  onChange: (speed: string) => void;
}

export default function PlaybackSpeedPicker({ speed, disabled, onChange }: PlaybackSpeedPickerProps) {
  const { t } = useI18n();
  const label = t("controls.speed");

  return (
    <select className="playback-speed-picker" aria-label={label} title={label}
      disabled={disabled} value={speed} onChange={(event) => onChange(event.target.value)}>
      {playbackRates(speed).map((rate) => <option key={rate} value={rate}>{formatPlaybackRate(rate)}</option>)}
    </select>
  );
}
