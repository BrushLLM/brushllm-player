import Foundation

/// WebDAV client: directory listing via PROPFIND, playback URL construction.
///
/// All requests run on URLSession's concurrent queues; playback itself is
/// handled by mpv's own threaded network stack.
enum WebDAVClient {

    enum WebDAVError: LocalizedError {
        case badURL
        case http(Int)
        case parse

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid WebDAV URL"
            case .http(let code): return "Server returned HTTP \(code)"
            case .parse: return "Could not parse the server response"
            }
        }
    }

    /// The absolute server path of the source's base directory.
    static func basePath(of source: MediaServerSource) -> String {
        guard let components = URLComponents(string: source.baseURL) else { return "/" }
        var path = components.path
        if !path.hasPrefix("/") { path = "/" + path }
        if path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    /// scheme://authority of the source, without any path.
    private static func origin(of source: MediaServerSource) -> String? {
        guard var components = URLComponents(string: source.baseURL),
              let host = components.host else { return nil }
        components.path = ""
        components.user = nil
        components.password = nil
        return components.url?.absoluteString
    }

    /// Lists a directory (PROPFIND, Depth 1). `path` is the absolute server
    /// path (starts with "/"). Runs off the main thread.
    static func list(source: MediaServerSource, path: String, password: String?) async throws -> [MediaItem] {
        guard let origin = origin(of: source) else { throw WebDAVError.badURL }
        guard let url = URL(string: origin + path) else { throw WebDAVError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
            <d:prop>
                <d:displayname/>
                <d:resourcetype/>
                <d:getcontentlength/>
            </d:prop>
        </d:propfind>
        """
        request.httpBody = Data(body.utf8)
        if !source.username.isEmpty, let password {
            let credentials = Data("\(source.username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw WebDAVError.http(http.statusCode)
        }
        guard let items = parseListing(data) else { throw WebDAVError.parse }
        // The first entry is the directory itself.
        return Array(items.dropFirst())
    }

    /// Builds the playback URL for a file (absolute server path), embedding
    /// credentials so mpv's HTTP stack can authenticate.
    static func playbackURL(source: MediaServerSource, path: String, password: String?) -> URL? {
        guard let origin = origin(of: source) else { return nil }
        guard var components = URLComponents(string: origin + path) else { return nil }
        if !source.username.isEmpty, let password {
            components.user = source.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
            components.password = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed)
        }
        return components.url
    }

    // MARK: - XML parsing

    private static func parseListing(_ data: Data) -> [MediaItem]? {
        let parser = ListingParser()
        let delegate = ListingDelegate(parser: parser)
        let xml = XMLParser(data: data)
        xml.delegate = delegate
        _ = xml.parse()
        return parser.items
    }

    private final class ListingParser {
        var items: [MediaItem] = []
    }

    private final class ListingDelegate: NSObject, XMLParserDelegate {
        private let listing: ListingParser
        private var currentPath: String?
        private var currentName: String?
        private var currentSize: Int64 = 0
        private var isDirectory = false
        private var currentText = ""
        private var inResourceType = false

        init(parser: ListingParser) { self.listing = parser }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String]) {
            currentText = ""
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            switch local {
            case "response":
                currentPath = nil
                currentName = nil
                currentSize = 0
                isDirectory = false
            case "resourcetype":
                inResourceType = true
            case "collection":
                if inResourceType { isDirectory = true }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            switch local {
            case "resourcetype":
                inResourceType = false
            case "href":
                if currentPath == nil {
                    currentPath = decodeHref(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            case "displayname":
                if currentName == nil {
                    currentName = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case "getcontentlength":
                currentSize = Int64(currentText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            case "response":
                if let href = currentPath {
                    let name = currentName ?? (href as NSString).lastPathComponent
                    let item = MediaItem(id: href, name: name, isDirectory: isDirectory, size: currentSize)
                    listing.items.append(item)
                }
            default:
                break
            }
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        /// Normalizes a WebDAV href into an absolute server path.
        private func decodeHref(_ href: String) -> String {
            var decoded = href.removingPercentEncoding ?? href
            if !decoded.hasPrefix("/") { decoded = "/" + decoded }
            if decoded.count > 1 && decoded.hasSuffix("/") { decoded.removeLast() }
            return decoded
        }
    }
}
