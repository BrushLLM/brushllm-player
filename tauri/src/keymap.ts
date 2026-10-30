// Keymap ported from IINA's default mpv input.conf
// (iina/Resources/config/input.conf). Only playback-control bindings that
// have a counterpart in this player are kept; IINA-specific bindings
// (the "#@iina" panel toggles, mouse/wheel-only entries, window-scale,
// panscan, secondary-subtitle and stats/console script bindings) are
// dropped because there is no matching UI or surface yet.
//
// `command` is one of our action names:
//   - "toggle_pause"          -> runCommand("toggle_pause")
//   - "seek_relative"         -> runCommand("seek_relative", { seconds })
//   - "set_property"          -> runCommand("set_property", { name, value })
//   - "send_command"          -> runCommand("send_command", { args }) (raw
//                                mpv command passthrough)
//   - "screenshot"            -> runCommand("screenshot")
//   - "stop_playback"         -> runCommand("stop_playback")
//   - "toggle_playlist_panel" -> handled locally by the UI (KeyboardHandler
//                                routes it to onTogglePlaylist instead)
//
// Keys are stored in the exact form the browser reports for
// `event.key` (case-sensitive for printable characters, e.g. "s" vs "S").

export interface KeyAction {
  command: string;
  args?: string[];
  description: string;
}

export const KEYMAP: Record<string, KeyAction> = {
  // Playback ----------------------------------------------------------------
  " ": { command: "toggle_pause", description: "Toggle pause/playback" },
  p: { command: "toggle_pause", description: "Toggle pause/playback" },

  // Seeking -----------------------------------------------------------------
  ArrowRight: { command: "seek_relative", args: ["5"], description: "Seek 5 seconds forward" },
  ArrowLeft: { command: "seek_relative", args: ["-5"], description: "Seek 5 seconds backward" },
  ArrowUp: { command: "seek_relative", args: ["60"], description: "Seek 1 minute forward" },
  ArrowDown: { command: "seek_relative", args: ["-60"], description: "Seek 1 minute backward" },
  PageUp: { command: "send_command", args: ["add", "chapter", "1"], description: "Seek to the next chapter" },
  PageDown: { command: "send_command", args: ["add", "chapter", "-1"], description: "Seek to the previous chapter" },

  // Speed -------------------------------------------------------------------
  "[": { command: "send_command", args: ["multiply", "speed", "0.909091"], description: "Decrease the playback speed" },
  "]": { command: "send_command", args: ["multiply", "speed", "1.1"], description: "Increase the playback speed" },
  "{": { command: "send_command", args: ["multiply", "speed", "0.5"], description: "Halve the playback speed" },
  "}": { command: "send_command", args: ["multiply", "speed", "2.0"], description: "Double the playback speed" },
  Backspace: { command: "set_property", args: ["speed", "1.0"], description: "Reset the speed to normal" },

  // Frame stepping ----------------------------------------------------------
  ".": { command: "send_command", args: ["frame-step"], description: "Advance one frame and pause" },
  ",": { command: "send_command", args: ["frame-back-step"], description: "Go back by one frame and pause" },

  // Volume ------------------------------------------------------------------
  "9": { command: "send_command", args: ["add", "volume", "-2"], description: "Decrease the volume" },
  "/": { command: "send_command", args: ["add", "volume", "-2"], description: "Decrease the volume" },
  "0": { command: "send_command", args: ["add", "volume", "2"], description: "Increase the volume" },
  "*": { command: "send_command", args: ["add", "volume", "2"], description: "Increase the volume" },
  m: { command: "send_command", args: ["cycle", "mute"], description: "Toggle mute" },

  // Playlist ----------------------------------------------------------------
  ">": { command: "send_command", args: ["playlist-next", "weak"], description: "Skip to the next file" },
  Enter: { command: "send_command", args: ["playlist-next", "weak"], description: "Skip to the next file" },
  "<": { command: "send_command", args: ["playlist-prev", "weak"], description: "Skip to the previous file" },

  // Chapters ----------------------------------------------------------------
  "!": { command: "send_command", args: ["add", "chapter", "-1"], description: "Seek to the previous chapter" },
  "@": { command: "send_command", args: ["add", "chapter", "1"], description: "Seek to the next chapter" },

  // Looping -----------------------------------------------------------------
  l: { command: "send_command", args: ["ab-loop"], description: "Set/clear A-B loop points" },
  L: { command: "send_command", args: ["cycle-values", "loop-file", "inf", "no"], description: "Toggle infinite looping" },

  // Fullscreen / stop -------------------------------------------------------
  f: { command: "send_command", args: ["cycle", "fullscreen"], description: "Toggle fullscreen" },
  q: { command: "send_command", args: ["quit"], description: "Quit" },
  Q: { command: "send_command", args: ["quit-watch-later"], description: "Exit and remember the playback position" },
  s: { command: "screenshot", description: "Take a screenshot of the video in its original resolution with subtitles" },
  S: { command: "send_command", args: ["screenshot", "video"], description: "Take a screenshot of the video in its original resolution without subtitles" },

  // Video -------------------------------------------------------------------
  A: {
    command: "send_command",
    args: ["cycle-values", "video-aspect-override", "16:9", "4:3", "2.35:1", "-1"],
    description: "Cycle the video aspect ratio",
  },
  d: { command: "send_command", args: ["cycle", "deinterlace"], description: "Toggle the deinterlacing filter" },
  h: { command: "send_command", args: ["cycle-values", "hwdec", "auto-safe", "no"], description: "Toggle hardware decoding" },

  // UI panels (local, no backend round-trip) ---------------------------------
  v: { command: "toggle_playlist_panel", description: "Toggle the playlist panel" },
};
