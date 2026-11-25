# BrushLLM Player desktop interface

The desktop window is a workspace for finding media and watching it. The two implementations share the same layout, semantic colors and control hierarchy. Each uses its platform’s system sans-serif and window chrome.

```text
┌─ BrushLLM Player ─┬─ Sidebar toggle · Media title · Open files ─┐
│ Sources           │                                            │
│ Playlist          │                  Video                     │
│ History           │                                            │
│ Bookmarks         ├─ Elapsed ───────── Timeline ───── Duration ┤
│ Selected section  │ Transport              Sound · Viewing    │
│ Settings · About  │                                            │
└───────────────────┴────────────────────────────────────────────┘
```

## Colors

| Role | Light | Dark |
| --- | --- | --- |
| Window | `#F5F4F0` | `#171717` |
| Rail | `#ECEBE6` | `#1D1D1D` |
| Raised surface | `#FFFEFC` | `#252525` |
| Text | `#202624` | `#F2F2F1` |
| Secondary text | `#545D58` | `#B5B7B4` |
| Play, selection, progress, and focus | `#20594F` | `#C6DED2` |
| Text on accent | `#F2F2F1` | `#17221E` |
| Copper detail in the mark | `#A55337` | `#A55337` |
| Video matte | `#101010` | `#101010` |

## Layout and interaction

- Use the BrushLLM website mark with the full product name in the sidebar. Use line icons, 8 px control corners, a 12 px screen corner, and a 4/8 px spacing rhythm.
- The sidebar is 200 px expanded and 64 px compact. It condenses below 800 px. Selecting a destination in the compact rail expands its content. The sidebar remembers the user’s choice separately at wide and narrow widths, including across viewing modes. Keyboard focus uses a visible outline, and selected destinations expose their state to assistive technology.
- Sources keeps file, URL and server entry points together. Playlist, history and bookmarks render beneath the navigation, leaving the video visible. Chapters are available from playback options.
- The video matte and full-width timeline form the primary visual unit. Previous, play/pause, next and stop are grouped. Sound and viewing actions are separated from transport. Less frequent options stay in a secondary panel.
- The media title uses the theme text color. Hovering the timeline in the ordinary window shows the target time.
- Fullscreen and mini remove navigation and the media header. Playback remains available through compact dark controls and existing shortcuts. Fullscreen fills the viewport and mini restores the ordinary window when closed.

Both apps use the same mark asset and system type. The native app uses SwiftUI and SF Symbols. The Tauri frontend uses CSS tokens and line icons. [BrushLLM website](https://brushllm.com/zh-CN/)
