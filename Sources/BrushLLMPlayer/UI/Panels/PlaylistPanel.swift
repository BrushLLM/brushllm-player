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
    }

    // MARK: - Header (tab picker)

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(SidebarTab.allCases) { candidate in
                Button {
                    tab = candidate
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: candidate.icon)
                            .font(.system(size: 9, weight: .bold))
                        Text(candidate.title)
                            .font(.system(size: 11, weight: tab == candidate ? .bold : .regular))
                            .lineLimit(1)
                    }
                    // Sidebar tabs highlight in mint (distinct from the lemon
                    // selection accent used inside the panels).
                    .foregroundStyle(tab == candidate ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background {
                        if tab == candidate {
                            Capsule().fill(BrushPalette.mint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .lineLimit(1)
                .fixedSize()
            }
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: - Playlist

    private var playlistContent: some View {
        Group {
            if player.playlist.isEmpty {
                emptyState(L("panel.playlist.empty", "Playlist is empty"))
            } else {
                List {
                    ForEach(player.playlist) { item in
                        playlistRow(item)
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in
                        // Drag-and-drop moves a single row in practice.
                        if let from = source.first {
                            player.movePlaylistItem(from: from, to: destination)
                        }
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
            Button {
                if let index = player.playlist.firstIndex(where: { $0.id == item.id }) {
                    player.playPlaylistIndex(index)
                }
            } label: {
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
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background {
                if item.isCurrent {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(BrushLLMPlayerTheme.accent)
                }
            }

            rowDeleteButton {
                if let index = player.playlist.firstIndex(where: { $0.id == item.id }) {
                    player.removePlaylistIndex(index)
                }
            }
        }
    }

    /// Small trailing delete button shown on every list row.
    private func rowDeleteButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary.opacity(0.55))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(L("panel.delete", "Delete"))
    }

    private func emptyState(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Chapters

    private var chaptersContent: some View {
        Group {
            if player.chapters.isEmpty {
                emptyState(L("panel.chapters.none", "No chapters"))
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
        Button {
            player.seekToChapter(chapter.index)
        } label: {
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
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            if player.currentChapter == chapter.index {
                RoundedRectangle(cornerRadius: 6)
                    .fill(BrushLLMPlayerTheme.accent)
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
                footerButton(icon: "shuffle", help: L("panel.playlist.shuffle", "Shuffle")) {
                    player.shufflePlaylist()
                }
                footerButton(icon: "trash", help: L("panel.playlist.clear", "Clear")) {
                    player.clearPlaylist()
                }
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
            case .bookmarks:
                footerButton(icon: "plus", help: L("menu.bookmark-add", "Add Bookmark")) {
                    player.addBookmark()
                }
                footerButton(icon: "trash", help: L("panel.bookmarks.clear", "Clear Bookmarks")) {
                    PlaybackStore.shared.removeBookmarks(at: IndexSet(integersIn: 0..<PlaybackStore.shared.bookmarks.count))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footerButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
        }
        .buttonStyle(.plain)
        .help(help)
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
