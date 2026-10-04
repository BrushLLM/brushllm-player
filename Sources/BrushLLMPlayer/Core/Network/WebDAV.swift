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
    ///
    /// Returned in its still-percent-encoded form: this value is the browse
    /// cursor fed back into `percentEncodedPath` (see `makeURL`) for the root
    /// listing, so it must not be decoded.
    static func basePath(of source: MediaServerSource) -> String {
        guard let components = URLComponents(string: source.baseURL) else { return "/" }
        var path = components.percentEncodedPath
        if !path.hasPrefix("/") { path = "/" + path }
        if path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    /// Builds a URL from an origin and an ALREADY percent-encoded absolute path.
    ///
    /// This must go through `percentEncodedPath`, never
    /// `URLComponents(string: origin + path)`: WebDAV hrefs routinely contain
    /// characters such as `#`, `?`, `+`, `&` (e.g. a file named
    /// `www.98T.la@#stripchat#…mp4`). Concatenating the *literal* characters
    /// into a URL string makes `#` start a fragment and `?` a query, so the
    /// path is truncated and playback 404s. Assigning the encoded path keeps
    /// `%23`/`%3F` intact.
    private static func makeURL(origin: String, encodedPath: String) -> URL? {
        guard var components = URLComponents(string: origin) else { return nil }
        components.percentEncodedPath = encodedPath
        return components.url
    }

    /// scheme://authority of the source, without any path.
    private static func origin(of source: MediaServerSource) -> String? {
        guard var components = URLComponents(string: source.baseURL),
              components.host != nil else { return nil }
        components.path = ""
        components.user = nil
        components.password = nil
        return components.url?.absoluteString
    }

    /// Lists a directory (PROPFIND, Depth 1). `path` is the percent-encoded
    /// absolute server path (starts with "/", e.g. from `basePath` or an
    /// item's href). Runs off the main thread.
    static func list(source: MediaServerSource, path: String, password: String?) async throws -> [MediaItem] {
        guard let origin = origin(of: source) else { throw WebDAVError.badURL }
        guard let url = makeURL(origin: origin, encodedPath: path) else { throw WebDAVError.badURL }

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

    /// Builds the playback URL for a file (percent-encoded absolute server
    /// path), embedding credentials so mpv's HTTP stack can authenticate.
    static func playbackURL(source: MediaServerSource, path: String, password: String?) -> URL? {
        guard let origin = origin(of: source) else { return nil }
        guard var components = URLComponents(string: origin) else { return nil }
        // percentEncodedPath keeps `#`/`?`/`+`/`&` in filenames encoded; see
        // makeURL above.
        components.percentEncodedPath = path
        if !source.username.isEmpty, let password {
            // URLComponents percent-encodes user/password itself when
            // serializing — pre-encoding here double-encodes ("p@ss" →
            // "p%40ss" → "p%2540ss") and the server rejects the password.
            components.user = source.username
            components.password = password
        }
        return components.url
    }

    /// Resolves a WebDAV file URL through any HTTP redirects and returns the
    /// FINAL location, so mpv opens the real content address directly.
    ///
    /// Why: WebDAV backends such as AList/OpenList on a 115 share answer a
    /// file GET with `302 → https://…115cdn.net/…?t=…&k=…`, a URL signed for
    /// one request. mpv follows that redirect, but on resume-from-pause and
    /// on seeks it re-opens the ORIGINAL WebDAV URL (a fresh 302 → a fresh
    /// signed URL) and the CDN answers the range request from offset 0 —
    /// "http: Unexpected offset: expected N, got 0" → "partial file", and
    /// playback dies. Handing mpv the already-resolved CDN URL avoids the
    /// re-redirect entirely. The CDN URL carries no per-request auth, so it
    /// is safe to cache for the playback session.
    ///
    /// Falls back to the input URL if there is no redirect or the request
    /// fails (e.g. a plain WebDAV server that serves bytes directly).
    ///
    /// The request must carry the SAME User-Agent mpv is configured with: the
    /// signed CDN URL these servers hand back is bound to the UA that asked
    /// for it, so a mismatch yields HTTP 403 when mpv fetches it. `userAgent`
    /// is `AppSettings.shared.userAgent`, the same value passed to mpv's
    /// `user-agent` option.
    static func resolvePlaybackURL(_ url: URL, source: MediaServerSource,
                                   password: String?, userAgent: String?) async -> URL {
        var request = URLRequest(url: url)
        // We only need the Location header, not the body.
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if !source.username.isEmpty, let password {
            let credentials = Data("\(source.username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await RedirectSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return url }
            // No redirect happened (2xx) — mpv can use the URL as-is.
            guard (300...399).contains(http.statusCode) else { return url }
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let final = URL(string: location, relativeTo: url)?.absoluteURL else { return url }
            return final
        } catch {
            return url
        }
    }

    /// A URLSession that does NOT follow redirects, so the 302's Location
    /// header is exposed to `resolvePlaybackURL` instead of being followed.
    private final class RedirectSession: NSObject, URLSessionTaskDelegate {
        static let shared: URLSession = {
            let delegate = RedirectSession()
            return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        }()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // Returning nil stops the redirect; the 302 response is delivered
            // to the data task's completion.
            completionHandler(nil)
        }
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
        ///
        /// The href is kept in its raw percent-encoded form (`%23`, `%20`,
        /// …). Decoding here would turn an encoded `#` back into a literal
        /// `#`, which later truncates the URL path (see `makeURL`). The
        /// encoded form is used as-is for both the next listing's request
        /// URL and the playback URL. The display name is shown separately, so
        /// no decoding is needed for the UI.
        private func decodeHref(_ href: String) -> String {
            var normalized = href
            if !normalized.hasPrefix("/") { normalized = "/" + normalized }
            if normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
            return normalized
        }
    }
}
