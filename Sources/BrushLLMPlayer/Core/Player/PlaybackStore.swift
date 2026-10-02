import Foundation

/// One entry in the playback history.
struct HistoryEntry: Identifiable, Codable, Equatable {
    var id: String { path }
    /// File path or URL string.
    let path: String
    var title: String
    var duration: Double
    /// Playback position when the file was last left, in seconds.
    var position: Double
    var lastPlayedAt: Date
    var playCount: Int
}

/// A named playback position within a file.
struct Bookmark: Identifiable, Codable, Equatable {
    var id: String { "\(path)#\(String(format: "%.2f", time))" }
    /// File path or URL string the bookmark belongs to.
    let path: String
    var title: String
    /// Bookmark position in seconds.
    var time: Double
    var note: String
    var createdAt: Date
}

/// Persistent store for playback history and bookmarks.
///
/// JSON file in Application Support with atomic writes; history is capped so
/// the file stays small. mpv's own `watch-later` handles automatic resume of
/// the exact playback position — this store powers the history/bookmark UI.
/// All mutations happen on the main thread; the debounced save task hops
/// back via MainActor.run, so the unchecked conformance is safe.
final class PlaybackStore: ObservableObject, @unchecked Sendable {

    static let shared = PlaybackStore()

    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var bookmarks: [Bookmark] = []

    private let fileURL: URL
    private let maxHistoryEntries = 1000
    private var saveTask: Task<Void, Never>?

    private struct Payload: Codable {
        var history: [HistoryEntry] = []
        var bookmarks: [Bookmark] = []
    }

    private init() {
        let appSupport = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
                          ?? NSTemporaryDirectory()) + "/BrushLLM Player"
        try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        fileURL = URL(fileURLWithPath: appSupport + "/playback.json")
        load()
    }

    // MARK: - History

    /// Records that a file started playing.
    func recordPlay(path: String, title: String, duration: Double) {
        let key = path
        if let index = history.firstIndex(where: { $0.path == key }) {
            history[index].title = title
            history[index].duration = duration
            history[index].lastPlayedAt = Date()
            history[index].playCount += 1
        } else {
            history.insert(HistoryEntry(path: path, title: title, duration: duration,
                                        position: 0, lastPlayedAt: Date(), playCount: 1), at: 0)
            if history.count > maxHistoryEntries {
                history.removeLast(history.count - maxHistoryEntries)
            }
        }
        scheduleSave()
    }

    /// Updates the saved position of the currently playing file.
    func updatePosition(path: String, position: Double) {
        guard let index = history.firstIndex(where: { $0.path == path }) else { return }
        history[index].position = position
        scheduleSave()
    }

    /// Removes history entries; nil removes everything.
    func removeHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        scheduleSave()
    }

    func clearHistory() {
        history.removeAll()
        scheduleSave()
    }

    // MARK: - Bookmarks

    var bookmarksForCurrentFile: [Bookmark] {
        bookmarks
    }

    func bookmarks(for path: String) -> [Bookmark] {
        bookmarks.filter { $0.path == path }.sorted { $0.time < $1.time }
    }

    func addBookmark(path: String, title: String, time: Double, note: String = "") {
        let bookmark = Bookmark(path: path, title: title, time: time, note: note, createdAt: Date())
        guard !bookmarks.contains(where: { $0.id == bookmark.id }) else { return }
        bookmarks.append(bookmark)
        scheduleSave()
    }

    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        scheduleSave()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        history = payload.history
        bookmarks = payload.bookmarks
    }

    /// Debounced save: coalesces bursts of position updates into one write.
    /// References the singleton directly — a weak self capture is a mutable
    /// capture that Swift 6.0 concurrency checking rejects in Task closures.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            PlaybackStore.shared.saveNow()
        }
    }

    private func saveNow() {
        let payload = Payload(history: history, bookmarks: bookmarks)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Flushes pending writes immediately (called on quit).
    func flush() {
        saveTask?.cancel()
        saveNow()
    }
}
