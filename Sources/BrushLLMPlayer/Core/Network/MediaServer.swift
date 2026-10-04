import Foundation
import Security

/// The kind of a saved media server. Each kind has its own client
/// implementation (directory listing + playback URL construction).
enum MediaServerKind: String, Codable, CaseIterable, Identifiable {
    case webdav
    case smb
    case ftp
    case emby
    case jellyfin

    var id: String { rawValue }

    /// Icon for the server list card.
    var icon: String {
        switch self {
        case .webdav: return "externaldrive.connected.to.line.below"
        case .smb: return "server.rack"
        case .ftp: return "arrow.down.circle"
        case .emby, .jellyfin: return "play.square.stack"
        }
    }
}

/// A saved media server. `baseURL` is the kind-specific connection string
/// composed by the add form (e.g. `https://host:5006/dav` for WebDAV,
/// `smb://host/share` for SMB, `http://host:8096` for Emby/Jellyfin).
struct MediaServerSource: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kind: MediaServerKind
    var name: String
    var baseURL: String
    var username: String
}

/// One entry of a media server directory listing. For file-system-like
/// servers (WebDAV/SMB/FTP) `id` is the absolute path; for Emby/Jellyfin it
/// is the item id and `isDirectory` marks folders.
struct MediaItem: Identifiable {
    /// Path or item id — also the browse "cursor" for the next listing.
    let id: String
    let name: String
    let isDirectory: Bool
    let size: Int64
}

/// Manages media servers of all kinds: metadata in UserDefaults, passwords
/// in the Keychain. Migrates the legacy WebDAV-only store on first launch,
/// preserving source ids so existing Keychain passwords carry over.
final class MediaServerStore: ObservableObject {

    static let shared = MediaServerStore()

    @Published private(set) var sources: [MediaServerSource] = []

    private let defaultsKey = "mediaServers"
    private let legacyKey = "webdavSources"
    /// Same service as the legacy WebDAV store — passwords are keyed by
    /// source id, so migrated sources keep working without re-entry.
    private let keychainService = "dev.brushllm.player.webdav"

    private init() {
        migrateLegacyIfNeeded()
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([MediaServerSource].self, from: data) {
            sources = decoded
        }
    }

    // MARK: - CRUD

    @discardableResult
    func add(kind: MediaServerKind, name: String, baseURL: String, username: String, password: String) -> MediaServerSource {
        let source = MediaServerSource(kind: kind, name: name, baseURL: baseURL, username: username)
        savePassword(password, for: source.id)
        sources.append(source)
        persistMetadata()
        return source
    }

    func update(_ source: MediaServerSource, password: String?) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index] = source
        if let password {
            savePassword(password, for: source.id)
        }
        persistMetadata()
    }

    func remove(_ source: MediaServerSource) {
        sources.removeAll { $0.id == source.id }
        deletePassword(for: source.id)
        persistMetadata()
    }

    func password(for source: MediaServerSource) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: source.id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores an auxiliary secret for a source under a distinct account
    /// (e.g. an Emby access token) without touching the password entry.
    func setSecret(_ value: String, account: String, for source: MediaServerSource) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(source.id.uuidString).\(account)",
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func secret(account: String, for source: MediaServerSource) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(source.id.uuidString).\(account)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Legacy migration

    /// Converts the pre-multi-protocol WebDAV store (same fields minus the
    /// kind) into `MediaServerSource`s, preserving ids so the Keychain
    /// passwords stay valid.
    private struct LegacySource: Codable {
        var id: UUID
        var name: String
        var baseURL: String
        var username: String
    }

    private func migrateLegacyIfNeeded() {
        guard UserDefaults.standard.data(forKey: defaultsKey) == nil,
              let data = UserDefaults.standard.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode([LegacySource].self, from: data) else { return }
        let migrated = legacy.map {
            MediaServerSource(id: $0.id, kind: .webdav, name: $0.name, baseURL: $0.baseURL, username: $0.username)
        }
        if let encoded = try? JSONEncoder().encode(migrated) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    // MARK: - Keychain

    private func savePassword(_ password: String, for id: UUID) {
        let data = Data(password.utf8)
        deletePassword(for: id)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: data,
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func persistMetadata() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// Kind-based dispatch for browsing and playback: the UI talks to this
/// facade only, so each protocol's client stays an implementation detail.
enum MediaServerBrowser {

    /// The browse cursor for a server's root listing.
    static func rootPath(of source: MediaServerSource) -> String {
        switch source.kind {
        case .webdav:
            return WebDAVClient.basePath(of: source)
        case .smb:
            return ""
        case .ftp:
            return FTPClient.rootPath(of: source)
        case .emby, .jellyfin:
            return ""
        }
    }

    /// Lists the children at `path` (a cursor from `rootPath` or an item id).
    static func list(source: MediaServerSource, path: String) async throws -> [MediaItem] {
        let password = MediaServerStore.shared.password(for: source)
        switch source.kind {
        case .webdav:
            return try await WebDAVClient.list(source: source, path: path, password: password)
        case .smb:
            return try SMBClient.list(source: source, path: path, password: password)
        case .ftp:
            return try await FTPClient.list(source: source, path: path, password: password)
        case .emby, .jellyfin:
            return try await EmbyClient.list(source: source, parentID: path, password: password)
        }
    }

    /// Resolves the playback URL for a file item.
    static func playbackURL(source: MediaServerSource, item: MediaItem) async -> URL? {
        let password = MediaServerStore.shared.password(for: source)
        switch source.kind {
        case .webdav:
            guard let url = WebDAVClient.playbackURL(source: source, path: item.id, password: password) else {
                return nil
            }
            // Resolve any 302 (e.g. 115 CDN) so mpv opens the final address
            // and never re-redirects on resume/seek — see resolvePlaybackURL.
            // The same User-Agent mpv uses is required: the signed URL is
            // bound to it.
            return await WebDAVClient.resolvePlaybackURL(url, source: source,
                                                         password: password,
                                                         userAgent: AppSettings.shared.userAgent)
        case .smb:
            return try? SMBClient.playbackURL(source: source, path: item.id, password: password)
        case .ftp:
            return FTPClient.playbackURL(source: source, path: item.id, password: password)
        case .emby, .jellyfin:
            return await EmbyClient.playbackURL(source: source, item: item, password: password)
        }
    }

    /// Releases per-server resources (SMB mounts). Called when the user
    /// leaves a server's browser.
    static func disconnect(source: MediaServerSource) {
        if source.kind == .smb {
            SMBClient.unmount(source: source)
        }
    }
}
