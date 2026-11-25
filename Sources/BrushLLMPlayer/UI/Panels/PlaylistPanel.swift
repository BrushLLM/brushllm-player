import SwiftUI

/// Contents of the active library section in the desktop sidebar.
struct PlayerLibraryPanel: View {
    @ObservedObject var player: PlayerCore
    let section: PlayerSidebarSection
    @ObservedObject private var store = PlaybackStore.shared
    @State private var clearRequested = false

    var body: some View {
        VStack(spacing: 0) {
            switch section {
            case .sources:
                EmptyView()
            case .playlist:
                playlistContent
            case .chapters:
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityAddTraits(.isHeader)
                chaptersContent
            case .history:
                HistoryPanel(player: player)
            case .bookmarks:
                BookmarksPanel(player: player)
            }
            if section != .sources {
                Divider().padding(.horizontal, 14)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.title)
        .confirmationDialog(L("panel.clear.question", "Clear this list?"), isPresented: $clearRequested,
                            titleVisibility: .visible) {
            Button(clearTitle, role: .destructive, action: clearSection)
            Button(L("panel.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("panel.clear.description", "Remove all entries from this list."))
        }
    }

    // MARK: - Playlist

    private var playlistContent: some View {
        Group {
            if player.playlist.isEmpty {
                EmptyStateView(icon: "music.note.list",
                               message: L("panel.playlist.empty", "Playlist is empty"))
            } else {
                List {
                    ForEach(player.playlist) { item in
                        playlistRow(item)
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in
                        player.movePlaylistItems(from: source, to: destination)
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) {
                            player.removePlaylistIndex(index)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func playlistRow(_ item: PlaylistItem) -> some View {
        HStack(spacing: 0) {
            SelectableRow(selected: item.isCurrent, action: {
                if let index = player.playlist.firstIndex(where: { $0.id == item.id }) {
                    player.playPlaylistIndex(index)
                }
            }) {
                HStack(spacing: 8) {
                    if item.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(item.isCurrent ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.accent)
                    }
                    Text(item.displayTitle)
                        .font(.callout)
                        .fontWeight(item.isCurrent ? .bold : .regular)
                        .foregroundStyle(item.isCurrent ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlTextSecondary)
                        .lineLimit(1)
                    Spacer()
                }
            }

            rowDeleteButton {
                if let index = player.playlist.firstIndex(where: { $0.id == item.id }) {
                    player.removePlaylistIndex(index)
                }
            }
        }
    }

    /// Trailing delete button shown on every list row: 14pt glyph in a
    /// 24×24 hit target, brightening on hover.
    private func rowDeleteButton(action: @escaping () -> Void) -> some View {
        HoverBrightButton(icon: "xmark.circle.fill", help: L("panel.delete", "Delete"), action: action)
    }

    // MARK: - Chapters

    private var chaptersContent: some View {
        Group {
            if player.chapters.isEmpty {
                EmptyStateView(icon: "list.and.film",
                               message: L("panel.chapters.none", "No chapters"))
            } else {
                List {
                    ForEach(player.chapters) { chapter in
                        chapterRow(chapter)
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func chapterRow(_ chapter: ChapterInfo) -> some View {
        SelectableRow(selected: player.currentChapter == chapter.index, action: {
            player.seekToChapter(chapter.index)
        }) {
            HStack(spacing: 8) {
                Text(chapter.title)
                    .font(.callout)
                    .fontWeight(player.currentChapter == chapter.index ? .bold : .regular)
                    .foregroundStyle(player.currentChapter == chapter.index ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlTextSecondary)
                    .lineLimit(1)
                Spacer()
                Text(playbackClock(chapter.startTime))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(player.currentChapter == chapter.index ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlTextSecondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(LoopMode.allCases) { mode in
                    Button {
                        player.setLoopMode(mode)
                    } label: {
                        if player.loopMode == mode {
                            Text("\(loopLabel(mode)) ✓")
                        } else {
                            Text(loopLabel(mode))
                        }
                    }
                }
            } label: {
                Image(systemName: loopIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(player.loopMode == .off ? BrushLLMPlayerTheme.controlTextSecondary : BrushLLMPlayerTheme.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("menu.loop", "Loop"))

            Spacer()

            switch section {
            case .sources:
                EmptyView()
            case .playlist:
                footerButton(icon: "square.and.arrow.up", help: L("playlist.export", "Export as M3U…"),
                             disabled: player.playlist.isEmpty) {
                    player.exportPlaylist()
                }
                footerButton(icon: "shuffle", help: L("panel.playlist.shuffle", "Shuffle"),
                             disabled: player.playlist.count < 2) {
                    player.shufflePlaylist()
                }
                clearButton(disabled: player.playlist.isEmpty)
            case .chapters:
                footerButton(icon: "backward.end.fill", help: L("menu.previous-chapter", "Previous Chapter")) {
                    player.previousChapter()
                }
                footerButton(icon: "forward.end.fill", help: L("menu.next-chapter", "Next Chapter")) {
                    player.nextChapter()
                }
            case .history:
                clearButton(disabled: store.history.isEmpty)
            case .bookmarks:
                footerButton(icon: "plus", help: L("menu.bookmark-add", "Add Bookmark"), disabled: player.isIdle) {
                    player.addBookmark()
                }
                clearButton(disabled: store.bookmarks.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footerButton(icon: String, help: String, disabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        PlayerIconButton(icon: icon, help: help, disabled: disabled, action: action)
    }

    private func clearButton(disabled: Bool) -> some View {
        footerButton(icon: "trash", help: clearTitle, disabled: disabled) { clearRequested = true }
            .padding(.leading, 8)
    }

    private var clearTitle: String {
        switch section {
        case .history: L("panel.history.clear", "Clear History")
        case .bookmarks: L("panel.bookmarks.clear", "Clear Bookmarks")
        default: L("panel.playlist.clear", "Clear Playlist")
        }
    }

    private func clearSection() {
        switch section {
        case .playlist: player.clearPlaylist()
        case .history: store.clearHistory()
        case .bookmarks: store.removeBookmarks(at: IndexSet(integersIn: 0..<store.bookmarks.count))
        case .sources, .chapters: break
        }
    }

    private var loopIcon: String {
        switch player.loopMode {
        case .off: return "repeat"
        case .file: return "repeat.1"
        case .playlist: return "repeat"
        }
    }

    private func loopLabel(_ mode: LoopMode) -> String {
        switch mode {
        case .off: return L("loop.off", "No Loop")
        case .file: return L("loop.file", "Loop File")
        case .playlist: return L("loop.playlist", "Loop Playlist")
        }
    }
}
