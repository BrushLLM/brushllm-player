export const playbackSpeedPresets = [0.5, 0.75, 1, 1.25, 1.5, 2] as const;

export function playbackRates(speed: number): readonly number[] {
  return [...new Set<number>([...playbackSpeedPresets, speed])].sort((a, b) => a - b);
}

export function formatPlaybackRate(rate: number): string {
  return `${Number(rate.toFixed(2))}×`;
}
