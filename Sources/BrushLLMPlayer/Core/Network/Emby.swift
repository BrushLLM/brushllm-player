import Foundation

enum EmbyClient {
    enum EmbyError: LocalizedError, Equatable {
        case badURL, auth, http(Int)
        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid server URL"
            case .auth: return "Authentication failed — check username and password"
            case .http(let code): return "Server returned HTTP \(code)"
            }
        }
    }

    struct Session: Codable {
        let userID: String
        let token: String
    }

    /// Token, API prefix and configuration identity commit in one atomic
    /// secret update. Unversioned legacy token/user entries are not trusted:
    /// their originating host/account cannot be established safely.
    private struct CachedSession: Codable {
        let configuration: MediaServerStore.Configuration
        let session: Session
        let usesEmbyPrefix: Bool
    }

    static func session(source: MediaServerSource, password: String?,
                        store: MediaServerStore = .shared, network: URLSession = .shared) async throws -> Session {
        try await authenticated(source: source, password: password, store: store, network: network).session
    }

    private static func authenticated(source: MediaServerSource, password: String?, store: MediaServerStore,
                                      network: URLSession, force: Bool = false, prefixHint: Bool? = nil) async throws -> CachedSession {
        let configuration = try store.configuration(for: source)
        let cached: CachedSession? = try store.withConfiguration(configuration) {
            guard let text = try store.readSecret(account: "embySession", for: source, configuration: configuration),
                  let value = try? JSONDecoder().decode(CachedSession.self, from: Data(text.utf8)),
                  value.configuration == configuration, !value.session.token.isEmpty, !value.session.userID.isEmpty else { return nil }
            return value
        }
        if !force, let cached { return cached }
        guard let password else { throw EmbyError.auth }
        struct AuthRequest: Encodable { let Username: String; let Pw: String }
        struct AuthResponse: Decodable {
            let AccessToken: String?
            let User: User?
            struct User: Decodable { let Id: String? }
        }
        let body = try JSONEncoder().encode(AuthRequest(Username: source.username, Pw: password))
        var usesPrefix = prefixHint ?? cached?.usesEmbyPrefix ?? false
        func authenticate(prefix: Bool) async throws -> (Data, HTTPURLResponse) {
            let url = try apiURL(source: source, usesPrefix: prefix, components: ["Users", "AuthenticateByName"])
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("MediaBrowser Client=\"BrushLLM Player\", Device=\"macOS\", DeviceId=\"BrushLLMPlayer\", Version=\"0.1\"",
                             forHTTPHeaderField: "X-Emby-Authorization")
            return try await execute(request, configuration: configuration, store: store, network: network)
        }
        var (data, response) = try await authenticate(prefix: usesPrefix)
        if response.statusCode == 404, !usesPrefix, !hasExplicitPrefix(source) {
            usesPrefix = true
            (data, response) = try await authenticate(prefix: true)
        }
        guard (200...299).contains(response.statusCode),
              let decoded = try? JSONDecoder().decode(AuthResponse.self, from: data),
              let token = decoded.AccessToken, !token.isEmpty, let userID = decoded.User?.Id, !userID.isEmpty else {
            throw EmbyError.auth
        }
        try Task.checkCancellation()
        let cachedSession = CachedSession(configuration: configuration, session: Session(userID: userID, token: token),
                                          usesEmbyPrefix: usesPrefix)
        let text = String(decoding: try JSONEncoder().encode(cachedSession), as: UTF8.self)
        return try store.withConfiguration(configuration) {
            // Another authentication for the same version may have committed
            // while this request was in flight. First valid commit wins;
            // a late login cannot replace the token a consumer already uses.
            if let currentText = try store.readSecret(account: "embySession", for: source, configuration: configuration),
               let current = try? JSONDecoder().decode(CachedSession.self, from: Data(currentText.utf8)),
               current.configuration == configuration, !current.session.token.isEmpty, !current.session.userID.isEmpty {
                return current
            }
            try store.setSecret(text, account: "embySession", for: source, configuration: configuration)
            return cachedSession
        }
    }

    static func list(source: MediaServerSource, parentID: String, password: String?,
                     store: MediaServerStore = .shared, network: URLSession = .shared) async throws -> [MediaItem] {
        var cached = try await authenticated(source: source, password: password, store: store, network: network)
        for attempt in 0...1 {
            let query = [URLQueryItem(name: "ParentId", value: parentID.isEmpty ? nil : parentID),
                         URLQueryItem(name: "Fields", value: "Size,DateModified,MediaType"),
                         URLQueryItem(name: "SortBy", value: "SortName")].filter { $0.value != nil }
            let url = try apiURL(source: source, usesPrefix: cached.usesEmbyPrefix,
                                 components: ["Users", cached.session.userID, "Items"], query: query)
            var request = URLRequest(url: url)
            request.setValue(cached.session.token, forHTTPHeaderField: "X-Emby-Token")
            let (data, response) = try await execute(request, configuration: cached.configuration, store: store, network: network)
            if response.statusCode == 401 {
                let replacement: CachedSession? = try store.withConfiguration(cached.configuration) {
                    if let text = try store.readSecret(account: "embySession", for: source, configuration: cached.configuration),
                       let current = try? JSONDecoder().decode(CachedSession.self, from: Data(text.utf8)),
                       current.configuration == cached.configuration, !current.session.token.isEmpty,
                       current.session.token != cached.session.token { return current }
                    try store.deleteSecret(account: "embySession", for: source, configuration: cached.configuration)
                    return nil
                }
                guard attempt == 0 else { throw EmbyError.auth }
                if let replacement { cached = replacement }
                else {
                    cached = try await authenticated(source: source, password: password, store: store, network: network,
                                                     force: true, prefixHint: cached.usesEmbyPrefix)
                }
                continue
            }
            guard (200...299).contains(response.statusCode) else { throw EmbyError.http(response.statusCode) }
            return try parseItems(data)
        }
        throw EmbyError.auth
    }

    static func parseItems(_ data: Data) throws -> [MediaItem] {
        struct ItemsResponse: Decodable {
            let Items: [Item]
            struct Item: Decodable {
                let Name: String?
                let Id: String?
                let `Type`: String?
                let MediaType: String?
                let Size: Int64?
                let DateModified: String?
                let IsFolder: Bool?
            }
        }
        let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
        return decoded.Items.compactMap { item in
            guard let id = item.Id, !id.isEmpty, let name = item.Name else { return nil }
            let isFolder = item.IsFolder ?? ["Folder", "CollectionFolder", "UserView", "Series", "Season", "MusicAlbum", "MusicArtist"].contains(item.Type ?? "")
            let type: MediaItem.MediaType?
            switch item.MediaType?.lowercased() {
            case "audio": type = .audio
            case "video": type = .video
            case .some: type = nil
            case .none:
                switch item.Type {
                case "Audio": type = .audio
                case "Movie", "Episode", "Video", "MusicVideo": type = .video
                default: type = nil
                }
            }
            let modified = item.DateModified.flatMap { text -> Date? in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            }
            return MediaItem(id: id, name: name, isDirectory: isFolder, size: item.Size ?? 0,
                             modifiedAt: modified, mediaType: isFolder ? nil : type)
        }
    }

    static func playbackURL(source: MediaServerSource, item: MediaItem, password: String?,
                            store: MediaServerStore = .shared, network: URLSession = .shared) async -> URL? {
        guard item.isPlayable(for: source.kind), let mediaType = item.mediaType else { return nil }
        do {
            let cached = try await authenticated(source: source, password: password, store: store, network: network)
            try Task.checkCancellation()
            return try store.withConfiguration(cached.configuration) {
                let path = mediaType == .audio ? ["Audio", item.id, "universal"] : ["Videos", item.id, "stream"]
                var query = [URLQueryItem(name: "api_key", value: cached.session.token)]
                if mediaType == .video { query.insert(URLQueryItem(name: "Static", value: "true"), at: 0) }
                return try apiURL(source: source, usesPrefix: cached.usesEmbyPrefix, components: path, query: query)
            }
        } catch { return nil }
    }

    private static func hasExplicitPrefix(_ source: MediaServerSource) -> Bool {
        URLComponents(string: source.baseURL)?.path.split(separator: "/").last?.lowercased() == "emby"
    }

    private static func apiURL(source: MediaServerSource, usesPrefix: Bool, components path: [String],
                               query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: source.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else { throw EmbyError.badURL }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        var base = components.path
        while base.hasSuffix("/") { base.removeLast() }
        if usesPrefix && !hasExplicitPrefix(source) { base += "/emby" }
        components.path = base
        guard var url = components.url else { throw EmbyError.badURL }
        for component in path {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/"), !component.contains("\\") else { throw EmbyError.badURL }
            url.appendPathComponent(component)
        }
        guard var result = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EmbyError.badURL }
        result.queryItems = query.isEmpty ? nil : query
        guard let resultURL = result.url else { throw EmbyError.badURL }
        return resultURL
    }

    /// Emby tokens and password-bearing POST bodies cannot follow redirects.
    /// A per-request session avoids sharing automatic credential storage.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private final class PendingRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func start(_ task: URLSessionDataTask) {
            lock.lock(); defer { lock.unlock() }
            self.task = task
            if cancelled { task.cancel() } else { task.resume() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let task = self.task; lock.unlock()
            task?.cancel()
        }
    }

    private static func execute(_ request: URLRequest, configuration: MediaServerStore.Configuration,
                                store: MediaServerStore, network: URLSession) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let settings = network.configuration
        settings.urlCredentialStorage = nil
        settings.httpCookieStorage = nil
        settings.timeoutIntervalForRequest = 30
        settings.timeoutIntervalForResource = 45
        let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let pending = PendingRequest()
        let result: (Data, URLResponse) = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try store.withConfiguration(configuration) {
                        let task = session.dataTask(with: request) { data, response, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let response { continuation.resume(returning: (data ?? Data(), response)) }
                            else { continuation.resume(throwing: EmbyError.badURL) }
                        }
                        pending.start(task)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { pending.cancel() })
        try Task.checkCancellation()
        guard store.isCurrent(configuration) else { throw MediaServerStore.StoreError.staleSource }
        guard let http = result.1 as? HTTPURLResponse else { throw EmbyError.badURL }
        return (result.0, http)
    }
}
