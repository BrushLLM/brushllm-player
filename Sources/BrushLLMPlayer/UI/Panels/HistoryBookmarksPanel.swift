import SwiftUI

/// Playback history list: click to reopen, shows last position.
struct HistoryPanel: View {
    @ObservedObject var player: PlayerCore
    @ObservedObject private var store = PlaybackStore.shared

    var body: some View {
        Group {
            if store.history.isEmpty {
                emptyState(L("panel.history.empty", "No playback history yet"))
            } else {
                List {
                    ForEach(store.history) { entry in
                        row(entry)
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .listRowBackground(Color.clear)
                    }
                    .onDelete { offsets in
                        store.removeHistory(at: offsets)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
                    .background(BrushLLMPlayerTheme.panelMaterial)
            }
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 0) {
            Button {
                player.reopen(entry)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.callout)
                            .foregroundStyle(BrushLLMPlayerTheme.controlText)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(formatTime(entry.position) + " / " + formatTime(entry.duration))
                            Text("·")
                            Text(relativeDate(entry.lastPlayedAt))
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            deleteButton {
                if let index = store.history.firstIndex(where: { $0.path == entry.path }) {
                    store.removeHistory(at: IndexSet(integer: index))
                }
            }
        }
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

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Bookmarks for the current file: click to jump, swipe to delete.
struct BookmarksPanel: View {
    @ObservedObject var player: PlayerCore
    @ObservedObject private var store = PlaybackStore.shared

    var body: some View {
        Group {
            if store.bookmarks.isEmpty {
                emptyState(L("panel.bookmarks.empty", "No bookmarks yet"))
            } else {
                List {
                    ForEach(store.bookmarks) { bookmark in
                        row(bookmark)
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .listRowBackground(Color.clear)
                    }
                    .onDelete { offsets in
                        store.removeBookmarks(at: offsets)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 0) {
            Button {
                player.openBookmark(bookmark)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(BrushLLMPlayerTheme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bookmark.title)
                            .font(.callout)
                            .foregroundStyle(BrushLLMPlayerTheme.controlText)
                            .lineLimit(1)
                        Text(formatTime(bookmark.time))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            deleteButton {
                if let index = store.bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                    store.removeBookmarks(at: IndexSet(integer: index))
                }
            }
        }
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

    private func formatTime(_ seconds: Double) -> String {
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

/// Small trailing delete button shared by the history and bookmark rows.
extension HistoryPanel {
    fileprivate func deleteButton(action: @escaping () -> Void) -> some View {
        rowDelete(action: action)
    }
}

extension BookmarksPanel {
    fileprivate func deleteButton(action: @escaping () -> Void) -> some View {
        rowDelete(action: action)
    }
}

private func rowDelete(action: @escaping () -> Void) -> some View {
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
