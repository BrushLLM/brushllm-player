// Kind icon: one inline SVG per server kind, standing in for the mac SF
// Symbols (externaldrive / server.rack / arrow.down.circle / play.square.stack).

import type { ServerKind } from "../../server-state";

export function KindIcon({ kind }: { kind: ServerKind }) {
  switch (kind) {
    case "webdav":
      return (
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <rect x="3" y="13" width="18" height="6" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <path d="M5 13 V6.5 A1.5 1.5 0 0 1 6.5 5 H12 L14 7.5 H17.5 A1.5 1.5 0 0 1 19 9 V13" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
          <circle cx="7" cy="16" r="1" fill="currentColor" />
        </svg>
      );
    case "smb":
      return (
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <rect x="3" y="4" width="18" height="6" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <rect x="3" y="14" width="18" height="6" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <circle cx="7" cy="7" r="0.9" fill="currentColor" />
          <circle cx="7" cy="17" r="0.9" fill="currentColor" />
        </svg>
      );
    case "ftp":
      return (
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <circle cx="12" cy="12" r="8.6" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <path d="M12 7.5 V16.5 M8.5 13 L12 16.5 L15.5 13" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      );
    case "emby":
    case "jellyfin":
      return (
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <rect x="3" y="5" width="8" height="14" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <rect x="13" y="5" width="8" height="14" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <path d="M5.5 9.5 L8.5 12 L5.5 14.5 Z" fill="currentColor" />
          <path d="M15.5 9.5 L18.5 12 L15.5 14.5 Z" fill="currentColor" />
        </svg>
      );
  }
}
