import Foundation

enum WebDAVClient {
    enum WebDAVError: LocalizedError {
        case badURL, http(Int), parse
        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid WebDAV URL"
            case .http(let code): return "Server returned HTTP \(code)"
            case .parse: return "Could not parse the server response"
            }
        }
    }

    static func basePath(of source: MediaServerSource) -> String {
        guard let components = URLComponents(string: source.baseURL) else { return "/" }
        return normalizedPath(components.percentEncodedPath)
    }

    /// The setter for percentEncodedPath traps on malformed input. Validate
    /// first, including percent escapes, instead of trusting server hrefs.
    private static func makeURL(origin: String, encodedPath: String) -> URL? {
        guard validEncodedPath(encodedPath), var components = URLComponents(string: origin) else { return nil }
        components.percentEncodedPath = encodedPath
        return components.url
    }

    static func origin(of source: MediaServerSource) -> String? {
        guard var components = URLComponents(string: source.baseURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url?.absoluteString
    }

    static func list(source: MediaServerSource, path: String, password: String?,
                     session: URLSession = .shared) async throws -> [MediaItem] {
        guard let origin = origin(of: source), let url = makeURL(origin: origin, encodedPath: path) else { throw WebDAVError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop>
        <d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/>
        </d:prop></d:propfind>
        """.utf8)
        if let authorization = authorization(source: source, password: password) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        // Listings cannot move to an unrelated origin (and carry Basic auth).
        let configuration = session.configuration
        configuration.urlCredentialStorage = nil
        let guardedSession = URLSession(configuration: configuration, delegate: ListingRedirectGuard(origin: url), delegateQueue: nil)
        defer { guardedSession.invalidateAndCancel() }
        let (data, response) = try await guardedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.parse }
        guard (200...299).contains(http.statusCode) else { throw WebDAVError.http(http.statusCode) }
        guard let items = parseListing(data, requestURL: response.url ?? url) else { throw WebDAVError.parse }
        return items
    }

    static func playbackURL(source: MediaServerSource, path: String, password: String?) -> URL? {
        guard let origin = origin(of: source), let url = makeURL(origin: origin, encodedPath: path),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if !source.username.isEmpty, let password {
            components.user = source.username
            components.password = password
        }
        return components.url
    }

    /// Probe GET headers only. Range is a server hint, not a memory bound:
    /// the data delegate cancels at the response before accepting any body.
    /// A single deadline covers the whole redirect chain. An injected
    /// session supplies its configuration/URLProtocol classes, not its
    /// potentially automatic-redirect delegate or stored credentials.
    static func resolvePlaybackURL(_ url: URL, source: MediaServerSource,
                                   password: String?, userAgent: String?,
                                   session: URLSession? = nil, timeout: TimeInterval = 15,
                                   maxRedirects: Int = 8) async throws -> URL {
        guard timeout.isFinite, timeout > 0, maxRedirects >= 0,
              let sourceOrigin = origin(of: source).flatMap({ URL(string: $0) }),
              let initial = withoutCredentials(url), ["http", "https"].contains(initial.scheme?.lowercased() ?? "") else { throw WebDAVError.badURL }
        let deadline = Date().addingTimeInterval(timeout)
        var current = initial
        var visited: Set<String> = [initial.absoluteString]
        let configuration = session?.configuration ?? URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        for hop in 0...maxRedirects {
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0 else { throw URLError(.timedOut) }
            var request = URLRequest(url: current)
            request.httpMethod = "GET"
            request.timeoutInterval = deadline.timeIntervalSinceNow
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            if let userAgent, !userAgent.isEmpty { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            if sameOrigin(current, sourceOrigin), let value = authorization(source: source, password: password) {
                request.setValue(value, forHTTPHeaderField: "Authorization")
            }
            do {
                let response = try await HeaderProbe().response(request: request, configuration: configuration,
                                                               timeout: deadline.timeIntervalSinceNow)
                if (200...299).contains(response.statusCode) {
                    guard hop > 0 else { return url }
                    if sameOrigin(current, sourceOrigin), var components = URLComponents(url: current, resolvingAgainstBaseURL: false),
                       !source.username.isEmpty, let password {
                        components.user = source.username
                        components.password = password
                        return components.url ?? url
                    }
                    return current
                }
                guard [301, 302, 303, 307, 308].contains(response.statusCode) else {
                    throw WebDAVError.http(response.statusCode)
                }
                guard hop < maxRedirects,
                      let location = response.value(forHTTPHeaderField: "Location"), validEscapes(location),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL,
                      let components = URLComponents(url: next, resolvingAgainstBaseURL: false),
                      components.user == nil, components.password == nil,
                      ["http", "https"].contains(next.scheme?.lowercased() ?? ""), next.host != nil,
                      !(current.scheme?.lowercased() == "https" && next.scheme?.lowercased() != "https"),
                      !(initial.scheme?.lowercased() == "https" && next.scheme?.lowercased() != "https"),
                      let clean = withoutCredentials(next), visited.insert(clean.absoluteString).inserted else {
                    throw WebDAVError.badURL
                }
                current = clean
            } catch { throw error }
        }
        throw WebDAVError.badURL
    }

    private static func authorization(source: MediaServerSource, password: String?) -> String? {
        guard !source.username.isEmpty, let password else { return nil }
        return "Basic " + Data("\(source.username):\(password)".utf8).base64EncodedString()
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    private static func withoutCredentials(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.fragment = nil
        return components.url
    }

    private final class ListingRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let origin: URL
        init(origin: URL) { self.origin = origin }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, WebDAVClient.sameOrigin(url, origin) else { completionHandler(nil); return }
            completionHandler(request)
        }
    }

    private final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
        private var task: URLSessionDataTask?
        private var session: URLSession?
        private var timer: DispatchWorkItem?
        private var finished = false

        func response(request: URLRequest, configuration: URLSessionConfiguration, timeout: TimeInterval) async throws -> HTTPURLResponse {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.session = session
                    let task = session.dataTask(with: request)
                    self.task = task
                    let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
                    self.timer = timer
                    lock.unlock()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.001, timeout), execute: timer)
                    task.resume()
                }
            }, onCancel: { self.finish(.failure(CancellationError())) })
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
            finish(.success(response))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            completionHandler(.cancel)
            if let response = response as? HTTPURLResponse { finish(.success(response)) }
            else { finish(.failure(WebDAVError.parse)) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish(.failure(error ?? WebDAVError.parse))
        }

        private func finish(_ result: Result<HTTPURLResponse, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let task = self.task
            let session = self.session
            self.task = nil
            self.session = nil
            timer?.cancel()
            timer = nil
            lock.unlock()
            continuation?.resume(with: result)
            task?.cancel()
            session?.invalidateAndCancel()
        }
    }

    // MARK: - DAV multistatus parsing

    static func parseListing(_ data: Data, requestURL: URL) -> [MediaItem]? {
        let delegate = ListingDelegate(requestURL: requestURL)
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.shouldResolveExternalEntities = false
        xml.delegate = delegate
        guard xml.parse(), delegate.isMultistatus else { return nil }
        return delegate.items
    }

    private static func normalizedPath(_ path: String) -> String {
        var result = path.isEmpty ? "/" : path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func validEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func hex(_ value: UInt8) -> Bool { (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value) }
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { return false }
                index += 3
            } else {
                guard bytes[index] >= 32, bytes[index] != 127 else { return false }
                index += 1
            }
        }
        return true
    }

    private static func validEncodedPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), validEscapes(path), path.removingPercentEncoding != nil else { return false }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        allowed.insert(charactersIn: "%")
        return path.unicodeScalars.allSatisfy { allowed.contains($0) && $0.value < 128 }
    }

    private static func hrefPath(_ href: String, requestURL: URL) -> String? {
        guard !href.isEmpty, validEscapes(href), var base = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else { return nil }
        if !base.percentEncodedPath.hasSuffix("/") { base.percentEncodedPath += "/" }
        guard let baseURL = base.url, let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
              sameOrigin(url, requestURL), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              validEncodedPath(components.percentEncodedPath) else { return nil }
        return normalizedPath(components.percentEncodedPath)
    }

    private final class ListingDelegate: NSObject, XMLParserDelegate {
        struct Properties {
            var name: String?
            var size: Int64?
            var directory: Bool?
            var modified: Date?
            mutating func merge(_ other: Properties) {
                if let value = other.name { name = value }
                if let value = other.size { size = value }
                if let value = other.directory { directory = value }
                if let value = other.modified { modified = value }
            }
        }
        struct Element { let name: String; let namespace: String?; var text = "" }
        let requestURL: URL
        var items: [MediaItem] = []
        var isMultistatus = false
        private var stack: [Element] = []
        private var href: String?
        private var responseStatus: Int?
        private var propstatStatus: Int?
        private var properties = Properties()
        private var propstat = Properties()
        private var hasSuccessfulProperties = false
        private var seen: Set<String> = []

        init(requestURL: URL) { self.requestURL = requestURL }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            stack.append(Element(name: elementName, namespace: namespaceURI))
            guard namespaceURI == "DAV:" else { return }
            if stack.count == 1 { isMultistatus = elementName == "multistatus" }
            switch elementName {
            case "response":
                href = nil; responseStatus = nil; properties = Properties(); hasSuccessfulProperties = false
            case "propstat": propstat = Properties(); propstatStatus = nil
            case "resourcetype": if inPropstat { propstat.directory = false }
            case "collection": if inPropstat && stack.dropLast().last?.name == "resourcetype" { propstat.directory = true }
            default: break
            }
        }

        private var inPropstat: Bool { stack.contains { $0.name == "propstat" && $0.namespace == "DAV:" } }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !stack.isEmpty { stack[stack.count - 1].text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let element = stack.last else { return }
            let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = stack.dropLast().last?.name
            if namespaceURI == "DAV:" {
                switch elementName {
                case "href": if parent == "response" { href = text }
                case "status":
                    let parts = text.split(whereSeparator: { $0.isWhitespace })
                    let status = parts.count >= 2 ? Int(parts[1]) : nil
                    if parent == "propstat" { propstatStatus = status }
                    else if parent == "response" { responseStatus = status }
                case "displayname": if inPropstat { propstat.name = text.isEmpty ? nil : text }
                case "getcontentlength": if inPropstat { propstat.size = Int64(text).map { max(0, $0) } }
                case "getlastmodified": if inPropstat { propstat.modified = ISODateParser.rfc1123(text) }
                case "propstat":
                    if let status = propstatStatus, (200...299).contains(status) {
                        properties.merge(propstat); hasSuccessfulProperties = true
                    }
                case "response":
                    if hasSuccessfulProperties, responseStatus == nil || (200...299).contains(responseStatus!),
                       let href, let path = WebDAVClient.hrefPath(href, requestURL: requestURL),
                       path.removingPercentEncoding != WebDAVClient.normalizedPath(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/").removingPercentEncoding,
                       seen.insert(path).inserted {
                        let fallback = ((path.removingPercentEncoding ?? path) as NSString).lastPathComponent
                        items.append(MediaItem(id: path, name: properties.name ?? fallback,
                                               isDirectory: properties.directory ?? false, size: properties.size ?? 0,
                                               modifiedAt: properties.modified))
                    }
                default: break
                }
            }
            stack.removeLast()
        }
    }
}
