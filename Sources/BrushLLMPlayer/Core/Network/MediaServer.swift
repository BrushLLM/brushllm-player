import Foundation
import Combine
import Security

/// Injectable storage shared by server credentials and protected playback data.
protocol SecretStore {
    func data(account: String, service: String) throws -> Data?
    func set(_ data: Data, account: String, service: String) throws
    func delete(account: String, service: String) throws
}

struct SecretStoreError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Secret storage failed (\(status))"
    }
}

struct KeychainSecretStore: SecretStore {
    private func query(account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func data(account: String, service: String) throws -> Data? {
        var query = query(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        guard let data = item as? Data else { throw SecretStoreError(status: errSecDecode) }
        return data
    }

    func set(_ data: Data, account: String, service: String) throws {
        let query = query(account: account, service: service)
        let values = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
            // Another writer may have inserted the same account meanwhile.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    func delete(account: String, service: String) throws {
        let status = SecItemDelete(query(account: account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError(status: status)
        }
    }
}

enum MediaServerKind: String, Codable, CaseIterable, Identifiable {
    case webdav, smb, ftp, emby, jellyfin
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .webdav: return "externaldrive.connected.to.line.below"
        case .smb: return "server.rack"
        case .ftp: return "arrow.down.circle"
        case .emby, .jellyfin: return "play.square.stack"
        }
    }
}

struct MediaServerSource: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kind: MediaServerKind
    var name: String
    var baseURL: String
    var username: String
}

struct MediaItem: Identifiable {
    enum MediaType: String, Codable { case audio, video }
    let id: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    let mediaType: MediaType?

    init(id: String, name: String, isDirectory: Bool, size: Int64,
         modifiedAt: Date? = nil, mediaType: MediaType? = nil) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.mediaType = mediaType
    }

    func isPlayable(for kind: MediaServerKind) -> Bool {
        guard !isDirectory else { return false }
        switch kind {
        case .emby, .jellyfin: return mediaType != nil
        case .webdav, .ftp, .smb:
            return MediaTypes.playableExtensions.contains((name as NSString).pathExtension.lowercased())
        }
    }
}

enum MediaSortMode: String {
    case name, modified, size

    func apply(_ items: [MediaItem], ascending: Bool) -> [MediaItem] {
        items.sorted { compare($0, $1, ascending: ascending) == .orderedAscending }
    }

    /// All branches are lexicographic. Unknown dates are always last; a
    /// known/unknown pair must never fall back to a name comparison.
    private func compare(_ lhs: MediaItem, _ rhs: MediaItem, ascending: Bool) -> ComparisonResult {
        switch self {
        case .name:
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory ? .orderedAscending : .orderedDescending }
            let name = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if name != .orderedSame { return directional(name, ascending) }
        case .modified:
            let date = compareDates(lhs.modifiedAt, rhs.modifiedAt, ascending: ascending)
            if date != .orderedSame { return date }
        case .size:
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory ? .orderedDescending : .orderedAscending }
            if lhs.isDirectory {
                let date = compareDates(lhs.modifiedAt, rhs.modifiedAt, ascending: ascending)
                if date != .orderedSame { return date }
            } else if lhs.size != rhs.size {
                return directional(lhs.size < rhs.size ? .orderedAscending : .orderedDescending, ascending)
            }
        }
        let name = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if name != .orderedSame { return name }
        let exactName = lhs.name.compare(rhs.name)
        return exactName == .orderedSame ? lhs.id.compare(rhs.id) : exactName
    }

    private func compareDates(_ lhs: Date?, _ rhs: Date?, ascending: Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.some(let l), .some(let r)):
            return l == r ? .orderedSame : directional(l < r ? .orderedAscending : .orderedDescending, ascending)
        case (.some, .none): return .orderedAscending
        case (.none, .some): return .orderedDescending
        case (.none, .none): return .orderedSame
        }
    }

    private func directional(_ result: ComparisonResult, _ ascending: Bool) -> ComparisonResult {
        guard !ascending else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// Metadata uses the existing defaults key; the password service/account is
/// unchanged. Auxiliary sessions are configuration-version-bound and updated
/// under the same lock as editing/deletion, so late authentication cannot
/// resurrect deleted credentials.
final class MediaServerStore: ObservableObject {
    static let shared = MediaServerStore()
    static let keychainService = "dev.brushllm.player.webdav"
    @Published private(set) var sources: [MediaServerSource] = []
    @Published private(set) var lastError: Error?
    private var blockedSources: Set<UUID> = []

    struct Configuration: Codable, Equatable {
        let id: UUID
        let kind: MediaServerKind
        let baseURL: String
        let username: String
        let revision: UInt64
    }

    enum StoreError: LocalizedError {
        case staleSource, invalidSecret, invalidMetadata
        var errorDescription: String? {
            switch self {
            case .staleSource: return "The server configuration changed or was removed"
            case .invalidSecret: return "The stored credential could not be decoded"
            case .invalidMetadata: return "The saved server configuration could not be decoded"
            }
        }
    }

    private let defaults: UserDefaults
    private let secretStore: any SecretStore
    private let lock = NSRecursiveLock()
    private let defaultsKey = "mediaServers"
    private let legacyKey = "webdavSources"
    private let revisionKey = "mediaServerCredentialRevisions"
    private let auxiliaryKey = "mediaServerAuxiliaryAccounts"
    private let blockedKey = "mediaServerBlockedCredentials"
    private var revisions: [String: UInt64] = [:]
    private var auxiliaries: [String: [String]] = [:]
    private var loadFailed = false

    init(defaults: UserDefaults = .standard, secretStore: any SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secretStore = secretStore
        do {
            try migrateLegacyIfNeeded()
            if let data = defaults.data(forKey: defaultsKey) {
                sources = try JSONDecoder().decode([MediaServerSource].self, from: data)
            }
            if let data = defaults.data(forKey: revisionKey) {
                revisions = try JSONDecoder().decode([String: UInt64].self, from: data)
            }
            if let data = defaults.data(forKey: auxiliaryKey) {
                auxiliaries = try JSONDecoder().decode([String: [String]].self, from: data)
            }
            if let data = defaults.data(forKey: blockedKey) {
                blockedSources = Set(try JSONDecoder().decode([UUID].self, from: data))
            }
        } catch {
            loadFailed = true
            lastError = error
        }
    }

    @discardableResult
    func add(kind: MediaServerKind, name: String, baseURL: String, username: String, password: String) -> MediaServerSource? {
        lock.lock(); defer { lock.unlock() }
        do {
            guard !loadFailed else { throw StoreError.invalidMetadata }
            let source = MediaServerSource(kind: kind, name: name, baseURL: baseURL, username: username)
            let updated = sources + [source]
            let data = try JSONEncoder().encode(updated)
            try secretStore.set(Data(password.utf8), account: source.id.uuidString, service: Self.keychainService)
            revisions[source.id.uuidString] = 1
            persistRevisions()
            defaults.set(data, forKey: defaultsKey)
            sources = updated
            lastError = nil
            return source
        } catch { lastError = error; return nil }
    }

    @discardableResult
    func update(_ source: MediaServerSource, password: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            guard !loadFailed, let index = sources.firstIndex(where: { $0.id == source.id }) else { throw StoreError.staleSource }
            let old = sources[index]
            var updated = sources
            updated[index] = source
            let data = try JSONEncoder().encode(updated)
            if old.kind != source.kind || old.baseURL != source.baseURL || old.username != source.username || password != nil {
                invalidateRevision(source.id)
                try deleteAuxiliaries(for: source.id)
            }
            if let password {
                try secretStore.set(Data(password.utf8), account: source.id.uuidString, service: Self.keychainService)
            }
            defaults.set(data, forKey: defaultsKey)
            sources = updated
            blockedSources.remove(source.id)
            persistBlockedSources()
            lastError = nil
            return true
        } catch { lastError = error; return false }
    }

    @discardableResult
    func remove(_ source: MediaServerSource) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            guard !loadFailed, sources.contains(where: { $0.id == source.id }) else { throw StoreError.staleSource }
            let updated = sources.filter { $0.id != source.id }
            let data = try JSONEncoder().encode(updated)
            invalidateRevision(source.id)
            try deleteAuxiliaries(for: source.id)
            try secretStore.delete(account: source.id.uuidString, service: Self.keychainService)
            defaults.set(data, forKey: defaultsKey)
            sources = updated
            blockedSources.remove(source.id)
            persistBlockedSources()
            lastError = nil
            return true
        } catch { lastError = error; return false }
    }

    func configuration(for source: MediaServerSource) throws -> Configuration {
        lock.lock(); defer { lock.unlock() }
        guard !loadFailed, !blockedSources.contains(source.id), let current = sources.first(where: { $0.id == source.id }),
              current.kind == source.kind, current.baseURL == source.baseURL, current.username == source.username else {
            throw StoreError.staleSource
        }
        return Configuration(id: source.id, kind: source.kind, baseURL: source.baseURL,
                             username: source.username, revision: revisions[source.id.uuidString] ?? 0)
    }

    func isCurrent(_ configuration: Configuration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let source = sources.first(where: { $0.id == configuration.id }) else { return false }
        return (try? self.configuration(for: source)) == configuration
    }

    /// Covers the final request-start/cache-commit check without an await
    /// between validation and the operation. Never run network waits here.
    func withConfiguration<T>(_ configuration: Configuration, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard isCurrent(configuration) else { throw StoreError.staleSource }
        return try operation()
    }

    func readPassword(for source: MediaServerSource) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        // UI may still prefill the preserved password after a failed edit;
        // clients must first obtain a valid configuration (which is blocked
        // during partial writes/deletes) before issuing a request.
        guard sources.contains(where: { $0.id == source.id && $0.kind == source.kind && $0.baseURL == source.baseURL && $0.username == source.username }) else { throw StoreError.staleSource }
        return try string(account: source.id.uuidString)
    }

    /// Compatibility for UI prefilling; errors are observable, not treated as
    /// a successful read of an empty password by the network clients.
    func password(for source: MediaServerSource) -> String? {
        do { return try readPassword(for: source) }
        catch { lastError = error; return nil }
    }

    func setSecret(_ value: String, account: String, for source: MediaServerSource,
                   configuration expected: Configuration? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let current = try configuration(for: source)
        guard expected == nil || expected == current else { throw StoreError.staleSource }
        // Register before writing: even an interrupted write remains removable.
        var names = Set(auxiliaries[source.id.uuidString] ?? [])
        names.insert(account)
        auxiliaries[source.id.uuidString] = names.sorted()
        persistAuxiliaries()
        try secretStore.set(Data(value.utf8), account: "\(source.id.uuidString).\(account)", service: Self.keychainService)
    }

    func readSecret(account: String, for source: MediaServerSource,
                    configuration expected: Configuration? = nil) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        let current = try configuration(for: source)
        guard expected == nil || expected == current else { throw StoreError.staleSource }
        return try string(account: "\(source.id.uuidString).\(account)")
    }

    func secret(account: String, for source: MediaServerSource) -> String? {
        do { return try readSecret(account: account, for: source) }
        catch { lastError = error; return nil }
    }

    func deleteSecret(account: String, for source: MediaServerSource,
                      configuration expected: Configuration? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let current = try configuration(for: source)
        guard expected == nil || expected == current else { throw StoreError.staleSource }
        try secretStore.delete(account: "\(source.id.uuidString).\(account)", service: Self.keychainService)
    }

    private func string(account: String) throws -> String? {
        guard let data = try secretStore.data(account: account, service: Self.keychainService) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw StoreError.invalidSecret }
        return value
    }

    private func invalidateRevision(_ id: UUID) {
        // If a later delete/write fails, do not let new authentications use
        // the partially modified credential set until an edit succeeds.
        blockedSources.insert(id)
        persistBlockedSources()
        revisions[id.uuidString] = (revisions[id.uuidString] ?? 0) &+ 1
        persistRevisions()
    }

    private func deleteAuxiliaries(for id: UUID) throws {
        let names = Set(auxiliaries[id.uuidString] ?? []).union(["embyToken", "embyUser", "embySession", "embyPrefix"])
        var failure: Error?
        for name in names {
            do { try secretStore.delete(account: "\(id.uuidString).\(name)", service: Self.keychainService) }
            catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
        auxiliaries.removeValue(forKey: id.uuidString)
        persistAuxiliaries()
    }

    private func persistBlockedSources() {
        if let data = try? JSONEncoder().encode(Array(blockedSources)) { defaults.set(data, forKey: blockedKey) }
    }

    private func persistRevisions() {
        if let data = try? JSONEncoder().encode(revisions) { defaults.set(data, forKey: revisionKey) }
    }

    private func persistAuxiliaries() {
        if let data = try? JSONEncoder().encode(auxiliaries) { defaults.set(data, forKey: auxiliaryKey) }
    }

    private struct LegacySource: Codable { var id: UUID; var name: String; var baseURL: String; var username: String }
    private func migrateLegacyIfNeeded() throws {
        guard defaults.data(forKey: defaultsKey) == nil, let data = defaults.data(forKey: legacyKey) else { return }
        let legacy = try JSONDecoder().decode([LegacySource].self, from: data)
        let migrated = legacy.map { MediaServerSource(id: $0.id, kind: .webdav, name: $0.name, baseURL: $0.baseURL, username: $0.username) }
        defaults.set(try JSONEncoder().encode(migrated), forKey: defaultsKey)
        defaults.removeObject(forKey: legacyKey)
    }
}

enum MediaServerBrowser {
    static func rootPath(of source: MediaServerSource) -> String {
        switch source.kind {
        case .webdav: return WebDAVClient.basePath(of: source)
        case .smb, .emby, .jellyfin: return ""
        case .ftp: return FTPClient.rootPath(of: source)
        }
    }

    static func list(source: MediaServerSource, path: String) async throws -> [MediaItem] {
        let store = MediaServerStore.shared
        let configuration = try store.configuration(for: source)
        let password = try store.readPassword(for: source)
        let items: [MediaItem]
        switch source.kind {
        case .webdav: items = try await WebDAVClient.list(source: source, path: path, password: password)
        case .smb: items = try await Task.detached(priority: .utility) { try SMBClient.list(source: source, path: path, password: password) }.value
        case .ftp: items = try await FTPClient.list(source: source, path: path, password: password)
        case .emby, .jellyfin: items = try await EmbyClient.list(source: source, parentID: path, password: password)
        }
        try Task.checkCancellation()
        guard store.isCurrent(configuration) else { throw MediaServerStore.StoreError.staleSource }
        return items
    }

    static func playbackURL(source: MediaServerSource, item: MediaItem, resolveRedirects: Bool = true) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let store = MediaServerStore.shared
        let configuration: MediaServerStore.Configuration
        let password: String?
        do {
            configuration = try store.configuration(for: source)
            password = try store.readPassword(for: source)
        } catch { return nil }
        let result: URL?
        switch source.kind {
        case .webdav:
            guard let url = WebDAVClient.playbackURL(source: source, path: item.id, password: password) else { return nil }
            if resolveRedirects {
                result = try? await WebDAVClient.resolvePlaybackURL(url, source: source, password: password,
                                                              userAgent: AppSettings.shared.userAgent)
            } else { result = url }
        case .smb:
            result = try? await Task.detached(priority: .utility) { try SMBClient.playbackURL(source: source, path: item.id, password: password) }.value
        case .ftp: result = FTPClient.playbackURL(source: source, path: item.id, password: password)
        case .emby, .jellyfin: result = await EmbyClient.playbackURL(source: source, item: item, password: password)
        }
        guard !Task.isCancelled, store.isCurrent(configuration) else { return nil }
        return result
    }

    /// Leaving a browser is not a resource release: queued/playing files may
    /// still use the mount. Explicit release and app shutdown own that action.
    static func disconnect(source: MediaServerSource) {}
}
