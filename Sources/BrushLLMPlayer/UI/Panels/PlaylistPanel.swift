import SwiftUI

/// Playlist sidebar with two tabs: the playlist and the chapter list.
struct PlaylistPanel: View {
    @ObservedObject var player: PlayerCore

    private enum SidebarTab: String, CaseIterable, Identifiable {
        case playlist
        case chapters
        case history
        case bookmarks

        var id: String { rawValue }

        var title: String {
            switch self {
            case .playlist: return L("panel.playlist.title", "Playlist")
            case .chapters: return L("panel.chapters", "Chapters")
            case .history: return L("panel.history", "History")
            case .bookmarks: return L("panel.bookmarks", "Bookmarks")
            }
        }

        var icon: String {
            switch self {
            case .playlist: return "music.note.list"
            case .chapters: return "list.and.film"
            case .history: return "clock.arrow.circlepath"
            case .bookmarks: return "bookmark"
            }
        }
    }

    @State private var tab: SidebarTab = .playlist

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(BrushLLMPlayerTheme.controlSeparator)
            switch tab {
            case .playlist:
                playlistContent
            case .chapters:
                chaptersContent
            case .history:
                HistoryPanel(player: player)
            case .bookmarks:
                BookmarksPanel(player: player)
            }
            Divider().overlay(BrushLLMPlayerTheme.controlSeparator)
            footer
        }
        .background(BrushLLMPlayerTheme.panelMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(BrushLLMPlayerTheme.controlSeparator)
                .frame(width: 0.5)
        }
    }

    // MARK: - Header (tab picker)

    /// Tabs adapt to localization length: full icon+label when they fit the
    /// sidebar, icon-only otherwise (e.g. German "Wiedergabeliste"). The
    /// selected tab uses the accent capsule — one selection language across
    /// the whole app.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ForEach(SidebarTab.allCases) { candidate in
                    tabButton(candidate, showLabel: true)
                }
                Spacer(minLength: 2)
            }
            .fixedSize()
            HStack(spacing: 4) {
                ForEach(SidebarTab.allCases) { candidate in
                    tabButton(candidate, showLabel: false)
                }
                Spacer(minLength: 2)
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func tabButton(_ candidate: SidebarTab, showLabel: Bool) -> some View {
        Button {
            tab = candidate
        } label: {
            HStack(spacing: 3) {
                Image(systemName: candidate.icon)
                    .font(.system(size: 9, weight: .bold))
                if showLabel {
                    Text(candidate.title)
                        .font(.system(size: 11, weight: tab == candidate ? .bold : .regular))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(tab == candidate ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlTextSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background {
                if tab == candidate {
                    Capsule().fill(BrushLLMPlayerTheme.accent)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressedDimButtonStyle())
        .help(candidate.title)
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
                Text(formatTime(chapter.startTime))
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

            switch tab {
            case .playlist:
                footerButton(icon: "square.and.arrow.up", help: L("playlist.export", "Export as M3U…")) {
                    player.exportPlaylist()
                }
                footerButton(icon: "shuffle", help: L("panel.playlist.shuffle", "Shuffle")) {
                    player.shufflePlaylist()
                }
                // Destructive clear gets extra separation from Shuffle.
                footerButton(icon: "trash", help: L("panel.playlist.clear", "Clear")) {
                    player.clearPlaylist()
                }
                .padding(.leading, 8)
            case .chapters:
                footerButton(icon: "backward.end.fill", help: L("menu.previous-chapter", "Previous Chapter")) {
                    player.previousChapter()
                }
                footerButton(icon: "forward.end.fill", help: L("menu.next-chapter", "Next Chapter")) {
                    player.nextChapter()
                }
            case .history:
                footerButton(icon: "trash", help: L("panel.history.clear", "Clear History")) {
                    PlaybackStore.shared.clearHistory()
                }
                .padding(.leading, 8)
            case .bookmarks:
                footerButton(icon: "plus", help: L("menu.bookmark-add", "Add Bookmark")) {
                    player.addBookmark()
                }
                footerButton(icon: "trash", help: L("panel.bookmarks.clear", "Clear Bookmarks")) {
                    PlaybackStore.shared.removeBookmarks(at: IndexSet(integersIn: 0..<PlaybackStore.shared.bookmarks.count))
                }
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footerButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        PlayerIconButton(icon: icon, help: help, action: action)
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

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
