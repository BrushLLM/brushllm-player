import Foundation
import CryptoKit

struct MediaReference: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case localFile
        case remoteURL
        case server
        case protectedURL
    }

    let kind: Kind
    let location: String
    var sourceID: UUID?
    var name: String?
    var mediaType: MediaItem.MediaType?

    static func file(_ path: String) -> MediaReference {
        MediaReference(kind: .localFile, location: path)
    }

    static func url(_ url: URL) -> MediaReference {
        url.isFileURL ? .file(url.path) : MediaReference(kind: .remoteURL, location: url.absoluteString)
    }

    static func server(_ source: MediaServerSource, item: MediaItem) -> MediaReference {
        MediaReference(kind: .server, location: item.id, sourceID: source.id,
                       name: item.name, mediaType: item.mediaType)
    }

    static func legacy(_ path: String) -> MediaReference {
        if let url = URL(string: path), let scheme = url.scheme,
           scheme != "file", path.contains("://") {
            return .url(url)
        }
        if let url = URL(string: path), url.isFileURL { return .file(url.path) }
        return .file(path)
    }

    var key: String {
        switch kind {
        case .localFile, .remoteURL: return location
        case .server:
            return "brushplayer://server/\(sourceID?.uuidString ?? "")/\(Self.digest(location))"
        case .protectedURL: return "brushplayer://protected/\(location)"
        }
    }

    var requiresProtection: Bool {
        guard kind == .remoteURL, let components = URLComponents(string: location) else { return false }
        return components.user != nil || components.password != nil || !(components.query?.isEmpty ?? true)
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if kind == .localFile { return URL(fileURLWithPath: location).lastPathComponent }
        if kind == .remoteURL, let url = URL(string: location) {
            return url.lastPathComponent.isEmpty ? (url.host ?? "Media") : url.lastPathComponent
        }
        return "Media"
    }

    static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum PlaylistOrder {
    static func moving(_ count: Int, from offsets: IndexSet, to destination: Int) -> [Int] {
        let selected = offsets.filter { (0..<count).contains($0) }
        let remaining = (0..<count).filter { !offsets.contains($0) }
        let insertion = min(max(destination - selected.filter { $0 < destination }.count, 0), remaining.count)
        var result = remaining
        result.insert(contentsOf: selected, at: insertion)
        return result
    }
}
