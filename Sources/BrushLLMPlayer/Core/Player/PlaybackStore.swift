import Foundation

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id: String { path }
    var path: String
    var media: MediaReference?
    var title: String
    var duration: Double
    var position: Double
    var lastPlayedAt: Date
    var playCount: Int

    var reference: MediaReference { media ?? .legacy(path) }
}

struct Bookmark: Identifiable, Codable, Equatable {
    var id: String { "\(path)#\(String(format: "%.2f", time))" }
    var path: String
    var media: MediaReference?
    var title: String
    var time: Double
    var note: String
    var createdAt: Date

    var reference: MediaReference { media ?? .legacy(path) }
}

final class PlaybackStore: ObservableObject, @unchecked Sendable {
    static let shared = PlaybackStore()

    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private let secretStore: any SecretStore
    private let secretService = "dev.brushllm.player.playback"
    private let maxHistoryEntries = 1000
    private var saveTask: Task<Void, Never>?
    private var writesDisabled = false
    private var migrationBackup: String?

    private struct Payload: Codable {
        var version: Int? = 2
        var history: [HistoryEntry] = []
        var bookmarks: [Bookmark] = []
    }

    init(fileURL: URL? = nil, secretStore: any SecretStore = KeychainSecretStore()) {
        let support = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
                       ?? NSTemporaryDirectory()) + "/BrushLLM Player"
        self.fileURL = fileURL ?? URL(fileURLWithPath: support + "/playback.json")
        self.secretStore = secretStore
        load()
    }

    func protect(_ reference: MediaReference) throws -> MediaReference {
        guard reference.requiresProtection else { return reference }
        let account = "url.\(MediaReference.digest(reference.location))"
        try secretStore.set(Data(reference.location.utf8), account: account, service: secretService)
        return MediaReference(kind: .protectedURL, location: account, name: reference.displayName)
    }

    func originalReference(_ reference: MediaReference) throws -> MediaReference {
        guard reference.kind == .protectedURL else { return reference }
        guard let data = try secretStore.data(account: reference.location, service: secretService),
              let location = String(data: data, encoding: .utf8), let url = URL(string: location) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return .url(url)
    }

    func recordPlay(reference: MediaReference, title: String, duration: Double) {
        guard !writesDisabled else { return }
        do {
            let media = try protect(reference)
            let safeTitle = URLPrivacy.redact(title)
            if let index = history.firstIndex(where: { $0.path == media.key }) {
                var entry = history.remove(at: index)
                entry.media = media
                entry.title = safeTitle
                entry.duration = finite(duration)
                entry.lastPlayedAt = Date()
                entry.playCount += 1
                history.insert(entry, at: 0)
            } else {
                history.insert(HistoryEntry(path: media.key, media: media, title: safeTitle,
                                            duration: finite(duration), position: 0,
                                            lastPlayedAt: Date(), playCount: 1), at: 0)
            }
            if history.count > maxHistoryEntries { history.removeLast(history.count - maxHistoryEntries) }
            scheduleSave()
        } catch { lastError = error.localizedDescription }
    }

    func recordPlay(path: String, title: String, duration: Double) {
        recordPlay(reference: .legacy(path), title: title, duration: duration)
    }

    func updatePosition(path: String, position: Double) {
        guard !writesDisabled, let index = history.firstIndex(where: { $0.path == path }) else { return }
        history[index].position = finite(position)
        scheduleSave()
    }

    func position(for reference: MediaReference) -> Double? {
        history.first { $0.path == reference.key }?.position
    }

    func removeHistory(at offsets: IndexSet) {
        guard !writesDisabled else { return }
        history.remove(atOffsets: offsets)
        scheduleSave()
    }

    func clearHistory() {
        guard !writesDisabled else { return }
        history.removeAll()
        scheduleSave()
    }

    func bookmarks(for path: String) -> [Bookmark] {
        bookmarks.filter { $0.path == path }.sorted { $0.time < $1.time }
    }

    func addBookmark(reference: MediaReference, title: String, time: Double, note: String = "") {
        guard !writesDisabled, time.isFinite, time >= 0 else { return }
        do {
            let media = try protect(reference)
            let bookmark = Bookmark(path: media.key, media: media, title: URLPrivacy.redact(title),
                                    time: time, note: URLPrivacy.redact(note), createdAt: Date())
            guard !bookmarks.contains(where: { $0.id == bookmark.id }) else { return }
            bookmarks.append(bookmark)
            scheduleSave()
        } catch { lastError = error.localizedDescription }
    }

    func addBookmark(path: String, title: String, time: Double, note: String = "") {
        addBookmark(reference: .legacy(path), title: title, time: time, note: note)
    }

    func removeBookmarks(at offsets: IndexSet) {
        guard !writesDisabled else { return }
        bookmarks.remove(atOffsets: offsets)
        scheduleSave()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            var payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == nil || payload.version == 1 || payload.version == 2 else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            var changed = false
            history = payload.history.map { entry in
                var display = entry
                display.title = URLPrivacy.redact(display.title)
                return display
            }.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
            bookmarks = payload.bookmarks.map { bookmark in
                var display = bookmark
                display.title = URLPrivacy.redact(display.title)
                display.note = URLPrivacy.redact(display.note)
                return display
            }
            for index in payload.history.indices {
                let original = payload.history[index].reference
                let media = try protect(original)
                if media != original || payload.history[index].media == nil {
                    payload.history[index].media = media
                    payload.history[index].path = media.key
                    payload.history[index].title = URLPrivacy.redact(payload.history[index].title)
                    changed = true
                }
            }
            for index in payload.bookmarks.indices {
                let original = payload.bookmarks[index].reference
                let media = try protect(original)
                if media != original || payload.bookmarks[index].media == nil {
                    payload.bookmarks[index].media = media
                    payload.bookmarks[index].path = media.key
                    payload.bookmarks[index].title = URLPrivacy.redact(payload.bookmarks[index].title)
                    payload.bookmarks[index].note = URLPrivacy.redact(payload.bookmarks[index].note)
                    changed = true
                }
            }
            if changed {
                let account = "migration-backup.\(MediaReference.digest(fileURL.path))"
                try secretStore.set(data, account: account, service: secretService)
                migrationBackup = account
            }
            history = payload.history.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
            bookmarks = payload.bookmarks
            if changed { saveNow() }
            if lastError != nil { writesDisabled = true }
        } catch {
            // An unreadable source must never be replaced by an empty store.
            writesDisabled = true
            lastError = error.localizedDescription
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard !writesDisabled else { return }
        do {
            let payload = Payload(history: history, bookmarks: bookmarks)
            let data = try JSONEncoder().encode(payload)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            let backup = migrationBackup ?? "migration-backup.\(MediaReference.digest(fileURL.path))"
            try secretStore.delete(account: backup, service: secretService)
            migrationBackup = nil
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func flush() {
        saveTask?.cancel()
        saveNow()
    }

    private func finite(_ value: Double) -> Double { value.isFinite ? max(value, 0) : 0 }
}
