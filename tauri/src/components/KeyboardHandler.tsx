// Global keyboard handler. Looks up window keydown events in the KEYMAP
// table (ported from IINA's default input.conf) and forwards the matched
// action to the parent via onAction.
//
// Deliberately NOT intercepted:
//   - Escape and Tab (system/dialog focus behavior)
//   - any key while a text field or editable region is focused
//   - Space/Enter while a button, link or similar control is focused (they
//     must keep activating that control for keyboard accessibility)
//   - arrow keys while a range slider is focused (native adjustment)
//   - any combo with Ctrl/Meta/Alt modifiers (Shift is allowed: it selects
//     distinct entries like "S", "L", "{" or "}" in the KEYMAP table)

import { useEffect, useRef } from "react";
import { KEYMAP } from "../keymap";

export interface KeymapAction {
  command: string;
  args?: string[];
}

export interface KeyboardHandlerProps {
  /** When false, no keys are handled at all. */
  enabled: boolean;
  /** Receives every matched KEYMAP action. */
  onAction: (action: KeymapAction) => void;
  /** Optional local callback for the playlist panel toggle action. */
  onTogglePlaylist?: () => void;
}

function isTextEntryTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName;
  if (tag === "TEXTAREA" || tag === "SELECT" || target.isContentEditable) return true;
  if (tag === "INPUT") {
    const type = (target as HTMLInputElement).type;
    // Range/checkbox/radio/button inputs are controls, not text entry:
    // they are handled by the activation rule below instead.
    return type !== "range" && type !== "checkbox" && type !== "radio" && type !== "button";
  }
  return false;
}

function isActivatableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName;
  if (tag === "BUTTON" || tag === "A" || tag === "SUMMARY") return true;
  if (tag === "INPUT") {
    const type = (target as HTMLInputElement).type;
    return type === "checkbox" || type === "radio" || type === "button";
  }
  const role = target.getAttribute("role");
  return role !== null && role.startsWith("menuitem");
}

function isRangeTarget(target: EventTarget | null): boolean {
  return target instanceof HTMLInputElement && target.type === "range";
}

export default function KeyboardHandler({
  enabled,
  onAction,
  onTogglePlaylist,
}: KeyboardHandlerProps) {
  // Keep the latest callbacks without re-registering the listener on every
  // render, so a parent that recreates its handler each render still works.
  const onActionRef = useRef(onAction);
  const onTogglePlaylistRef = useRef(onTogglePlaylist);
  onActionRef.current = onAction;
  onTogglePlaylistRef.current = onTogglePlaylist;

  useEffect(() => {
    if (!enabled) return;

    const handleKeyDown = (event: KeyboardEvent) => {
      // Never intercept system keys.
      if (event.key === "Escape" || event.key === "Tab") return;
      // Ignore anything typed into a text field or editable region.
      if (isTextEntryTarget(event.target)) return;
      // Ignore modified combos (Shift is allowed, see the header comment).
      if (event.ctrlKey || event.metaKey || event.altKey) return;
      // Space/Enter on a focused control must activate that control.
      if ((event.key === " " || event.key === "Enter") && isActivatableTarget(event.target)) return;
      // Arrow keys on a focused range slider adjust the slider natively.
      if (event.key.startsWith("Arrow") && isRangeTarget(event.target)) return;

      const action = KEYMAP[event.key];
      if (!action) return;

      if (action.command === "toggle_playlist_panel") {
        if (onTogglePlaylistRef.current) {
          event.preventDefault();
          onTogglePlaylistRef.current();
        }
        return;
      }

      event.preventDefault();
      onActionRef.current({ command: action.command, args: action.args });
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [enabled]);

  return null;
}
