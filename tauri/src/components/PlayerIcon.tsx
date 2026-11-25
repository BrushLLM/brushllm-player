import type { ReactNode } from "react";

const icons = {
  folder: <path d="M3 7a2 2 0 0 1 2-2h4l2.5 2.5H19a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />,
  playlist: <path d="M4 6h16M4 12h16M4 18h10" />,
  history: <><path d="M3 12a9 9 0 1 1 2.7 6.4M3 7v5h5" /><path d="M12 7v5l3 2" /></>,
  bookmark: <path d="M6 4h12v16l-6-4-6 4Z" />,
  link: <><path d="m10 13 4-4m-6 6-1 1a3.5 3.5 0 0 1-5-5l4-4a3.5 3.5 0 0 1 5 0m2 2 1-1a3.5 3.5 0 0 1 5 5l-4 4a3.5 3.5 0 0 1-5 0" transform="translate(1 1)" /></>,
  servers: <><rect x="4" y="5" width="16" height="14" rx="2" /><path d="M4 13h16m-4 3h1" /></>,
  settings: <><circle cx="12" cy="12" r="3" /><path d="m10 3-.7 2.7-2 .9L5 5.5 3 9l2 1.9v2.2L3 15l2 3.5 2.3-1.1 2 .9L10 21h4l.7-2.7 2-.9 2.3 1.1 2-3.5-2-1.9v-2.2L21 9l-2-3.5-2.3 1.1-2-.9L14 3Z" /></>,
  info: <><circle cx="12" cy="12" r="9" /><path d="M12 11v5m0-8h.01" /></>,
  sidebar: <><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M9 5v14M5.5 9h1M5.5 12h1" /></>,
  screen: <><rect x="2.5" y="5" width="19" height="14" rx="2.5" /><path d="m10 9 5 3-5 3Z" /></>,
  previous: <path d="M6 6v12m12-11-8 5 8 5Z" />,
  next: <path d="M18 6v12M6 7l8 5-8 5Z" />,
  play: <path d="m8 5 11 7-11 7Z" fill="currentColor" stroke="none" />,
  pause: <path d="M7 5h3v14H7zM14 5h3v14h-3z" fill="currentColor" stroke="none" />,
  stop: <rect x="6" y="6" width="12" height="12" rx="1.8" />,
  volume: <><path d="M4 10h4l5-4v12l-5-4H4Z" /><path d="M16 9a4.5 4.5 0 0 1 0 6m3-8a8 8 0 0 1 0 10" /></>,
  mute: <><path d="M4 10h4l5-4v12l-5-4H4Z" /><path d="m16 10 4 4m0-4-4 4" /></>,
  speed: <path d="M4 17a8 8 0 1 1 16 0H4Zm8-2 4-5M7 11l1 1m4-4v1" />,
  captions: <><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M6 12h5m2 0h5M6 15h3m2 0h7" /></>,
  adjustments: <path d="M4 6h7m4 0h5M4 12h3m4 0h9M4 18h11m4 0h1M11 4v4M7 10v4m8 2v4" />,
  equalizer: <path d="M4 10v4m4-8v12m4-15v18m4-16v14m4-9v4" />,
  camera: <><path d="M3 7h4l2-2h6l2 2h4v12H3Z" /><circle cx="12" cy="13" r="3" /></>,
  repeat: <path d="m17 3 3 3-3 3m-13 4V9a3 3 0 0 1 3-3h13M7 21l-3-3 3-3m13-4v4a3 3 0 0 1-3 3H4" />,
  pin: <path d="m16 3 5 5-3 1-3 4v4l-2 2-8-8 2-2h4l4-3 1-3ZM9 15l-5 5" />,
  seekBack: <path d="M11 7 5 12l6 5m8-10-6 5 6 5" />,
  seekForward: <path d="m5 7 6 5-6 5m8-10 6 5-6 5" />,
  fullscreen: <path d="M9 4H4v5m11-5h5v5M4 15v5h5m11-5v5h-5" />,
  fullscreenExit: <path d="M4 9h5V4m11 5h-5V4m-6 16v-5H4m11 5v-5h5" />,
  chevronLeft: <path d="m15 6-6 6 6 6" />,
  chevronRight: <path d="m9 6 6 6-6 6" />,
  mini: <><rect x="3" y="5" width="18" height="14" rx="2" /><rect x="12" y="12" width="6" height="4" rx="0.5" /></>,
  miniExit: <><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M12 13h5m0 0V8m0 5 3-3" /></>,
  close: <path d="m6 6 12 12M18 6 6 18" />,
  back: <path d="M19 12H5m6 6-6-6 6-6" />,
} satisfies Record<string, ReactNode>;

export type PlayerIconName = keyof typeof icons;

export default function PlayerIcon({ name }: { name: PlayerIconName }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65"
      strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      {icons[name]}
    </svg>
  );
}
