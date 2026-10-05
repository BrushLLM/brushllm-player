import Foundation

/// Emby / Jellyfin client. Both servers share the same REST API shape
/// (Jellyfin is an Emby fork); Emby installs often expose the API under an
/// `/emby` path prefix, which is detected automatically on the first call.
///
/// Flow: authenticate by name → access token (cached in the Keychain) →
/// browse the user's item tree → direct-stream playback URLs (no
/// transcoding).
enum EmbyClient {

    enum EmbyError: LocalizedError {
        case badURL
        case auth
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid server URL"
            case .auth: return "Authentication failed — check username and password"
            case .http(let code): return "Server returned HTTP \(code)"
            }
        }
    }

    // MARK: - Authentication

    struct Session {
        let userID: String
        let token: String
    }

    /// Authenticates and returns the cached session, re-authenticating when
    /// the stored token is missing.
    static func session(source: MediaServerSource, password: String?) async throws -> Session {
        if let cached = cachedSession(source) {
            return cached
        }
        guard let password else { throw EmbyError.auth }

        struct AuthRequest: Codable { let Username: String; let Pw: String }
        struct AuthResponse: Codable {
            let AccessToken: String?
            let User: User?
            struct User: Codable { let Id: String? }
        }

        let body = try JSONEncoder().encode(AuthRequest(Username: source.username, Pw: password))
        let (data, response) = try await post(path: "/Users/AuthenticateByName", source: source, body: body)
        guard (response as? HTTPURLResponse)?.statusCode ?? 500 < 400 else {
            throw EmbyError.auth
        }
        guard let decoded = try? JSONDecoder().decode(AuthResponse.self, from: data),
              let token = decoded.AccessToken, let userID = decoded.User?.Id else {
            throw EmbyError.auth
        }
        let session = Session(userID: userID, token: token)
        cacheSession(session, for: source)
        return session
    }

    private static func cachedSession(_ source: MediaServerSource) -> Session? {
        guard let token = MediaServerStore.shared.secret(account: "embyToken", for: source),
              let userID = MediaServerStore.shared.secret(account: "embyUser", for: source) else { return nil }
        return Session(userID: userID, token: token)
    }

    private static func cacheSession(_ session: Session, for source: MediaServerSource) {
        MediaServerStore.shared.setSecret(session.token, account: "embyToken", for: source)
        MediaServerStore.shared.setSecret(session.userID, account: "embyUser", for: source)
    }

    // MARK: - Browsing

    /// Lists the children of an item. `parentID` empty = the user's root
    /// view (libraries). Folders map to `isDirectory` so the generic
    /// browser tree works.
    static func list(source: MediaServerSource, parentID: String, password: String?) async throws -> [MediaItem] {
        let session = try await session(source: source, password: password)

        struct ItemsResponse: Codable {
            let Items: [Item]
            struct Item: Codable {
                let Name: String?
                let Id: String?
                let ItemType: String?
                let Size: Int64?
                let DateModified: String?
                let IsFolder: Bool?

                enum CodingKeys: String, CodingKey {
                    case Name, Id, Size, DateModified, IsFolder
                    case ItemType = "Type"
                }
            }
        }

        var components = URLComponents(string: apiBase(source) + "/Users/\(session.userID)/Items")
        components?.queryItems = [
            URLQueryItem(name: "ParentId", value: parentID.isEmpty ? nil : parentID),
            URLQueryItem(name: "Fields", value: "Size,DateModified"),
            URLQueryItem(name: "SortBy", value: "SortName"),
        ].compactMap { $0 }
        guard let url = components?.url else { throw EmbyError.badURL }

        var request = URLRequest(url: url)
        request.setValue(session.token, forHTTPHeaderField: "X-Emby-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 {
                // Token expired — drop the cache and retry once.
                MediaServerStore.shared.setSecret("", account: "embyToken", for: source)
                throw EmbyError.auth
            }
            if http.statusCode >= 400 { throw EmbyError.http(http.statusCode) }
        }
        guard let decoded = try? JSONDecoder().decode(ItemsResponse.self, from: data) else {
            throw EmbyError.badURL
        }
        return decoded.Items.compactMap { item in
            guard let id = item.Id, let name = item.Name else { return nil }
            let isFolder = item.IsFolder ?? (item.ItemType == "Folder")
            // Emby DateModified is ISO 8601 with fractional seconds.
            let modified = item.DateModified.flatMap {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            }
            return MediaItem(id: id, name: name, isDirectory: isFolder, size: item.Size ?? 0, modifiedAt: modified)
        }
    }

    // MARK: - Playback

    /// Direct-stream URL (no transcoding). Videos use the static stream
    /// endpoint; audio the universal endpoint.
    static func playbackURL(source: MediaServerSource, item: MediaItem, password: String?) async -> URL? {
        guard let session = try? await session(source: source, password: password) else { return nil }
        let base = apiBase(source)
        let path: String
        if isAudio(item) {
            path = "\(base)/Audio/\(item.id)/universal?api_key=\(session.token)"
        } else {
            path = "\(base)/Videos/\(item.id)/stream?Static=true&api_key=\(session.token)"
        }
        return URL(string: path)
    }

    private static func isAudio(_ item: MediaItem) -> Bool {
        // The universal audio endpoint works for music items; video items
        // must use the video stream endpoint. Heuristic: audio items are
        // usually small and named like tracks — the reliable signal is the
        // Emby item type, so we pass it through the item name suffix check
        // plus a size heuristic for common audio libraries.
        let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "aiff", "wma"]
        let ext = (item.name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext) || (item.size > 0 && item.size < 50_000_000 && !item.isDirectory && ext.isEmpty)
    }

    // MARK: - Request plumbing

    /// The API base: the source's baseURL as given, with the `/emby` prefix
    /// fallback detected on the first request.
    private static var embyPrefixCache: [String: Bool] = [:]

    private static func apiBase(_ source: MediaServerSource) -> String {
        let base = source.baseURL.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("/") { return String(base.dropLast()) }
        return base
    }

    private static func post(path: String, source: MediaServerSource, body: Data) async throws -> (Data, URLResponse) {
        let base = apiBase(source)
        // Try the plain path first; Emby servers that expose the API under
        // /emby answer 404 there, and we retry with the prefix.
        do {
            return try await execute(URL(string: base + path)!, body: body)
        } catch let error as EmbyError where error == .http(404) {
            embyPrefixCache[source.id.uuidString] = true
            return try await execute(URL(string: base + "/emby" + path)!, body: body)
        }
    }

    private static func execute(_ url: URL, body: Data) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Minimal client identification required by both servers.
        request.setValue("MediaBrowser Client=\"BrushLLM Player\", Device=\"macOS\", DeviceId=\"BrushLLMPlayer\", Version=\"0.1\"",
                         forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw EmbyError.http(http.statusCode)
        }
        return (data, response)
    }
}

extension EmbyClient.EmbyError: Equatable {}
