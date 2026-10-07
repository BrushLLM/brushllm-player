import Foundation
import Network

/// Callback transport seam used by the protocol tests; fakes never open TCP.
protocol FTPConnection: AnyObject {
    func start(queue: DispatchQueue, completion: @escaping (Result<Void, Error>) -> Void)
    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void)
    func receive(maximumLength: Int, completion: @escaping (Result<(Data, Bool), Error>) -> Void)
    func cancel()
}

final class NWFTPConnection: FTPConnection {
    private let connection: NWConnection
    init(host: String, port: Int) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
    }
    func start(queue: DispatchQueue, completion: @escaping (Result<Void, Error>) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: completion(.success(()))
            case .failed(let error): completion(.failure(error))
            case .cancelled: completion(.failure(CancellationError()))
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        })
    }
    func receive(maximumLength: Int, completion: @escaping (Result<(Data, Bool), Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, done, error in
            if let error { completion(.failure(error)) } else { completion(.success((content ?? Data(), done))) }
        }
    }
    func cancel() { connection.cancel() }
}

enum FTPClient {
    typealias ConnectionFactory = (String, Int) -> any FTPConnection
    enum FTPError: LocalizedError {
        case badURL, connection(String), login, listing, timeout, responseTooLarge
        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid FTP URL"
            case .connection(let detail): return "Could not connect: \(detail)"
            case .login: return "Login failed — check username and password"
            case .listing: return "Could not read the directory listing"
            case .timeout: return "The FTP server did not respond in time"
            case .responseTooLarge: return "The FTP directory listing is too large"
            }
        }
    }

    static func list(source: MediaServerSource, path: String, password: String?, timeout: TimeInterval = 30,
                     connectionFactory: @escaping ConnectionFactory = { NWFTPConnection(host: $0, port: $1) }) async throws -> [MediaItem] {
        guard let components = URLComponents(string: source.baseURL), components.scheme?.lowercased() == "ftp",
              let host = components.host, (1...65535).contains(components.port ?? 21),
              timeout.isFinite, timeout > 0 else { throw FTPError.badURL }
        let session = try await FTPSession(host: host, port: components.port ?? 21, timeout: timeout, factory: connectionFactory)
        defer { session.close() }
        try await session.login(username: source.username.isEmpty ? "anonymous" : source.username, password: password ?? "")
        let raw = try await session.listDirectory(path: path)
        guard let parsed = parseListing(raw) else { throw FTPError.listing }
        return items(parsed, under: path)
    }

    static func items(_ listing: [MediaItem], under path: String) -> [MediaItem] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return listing.filter { $0.name != "." && $0.name != ".." }.map {
            MediaItem(id: prefix + $0.name, name: $0.name, isDirectory: $0.isDirectory,
                      size: $0.size, modifiedAt: $0.modifiedAt)
        }
    }

    static func rootPath(of source: MediaServerSource) -> String {
        guard let components = URLComponents(string: source.baseURL) else { return "/" }
        var path = components.path
        if !path.hasPrefix("/") { path = "/" + path }
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    static func playbackURL(source: MediaServerSource, path: String, password: String?) -> URL? {
        guard var components = URLComponents(string: source.baseURL), components.scheme?.lowercased() == "ftp",
              components.host != nil else { return nil }
        components.user = source.username.isEmpty ? "anonymous" : source.username
        components.password = password ?? ""
        components.path = path.hasPrefix("/") ? path : "/" + path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func parseListing(_ raw: String) -> [MediaItem]? {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        var items: [MediaItem] = []
        var parsedAny = false
        for line in lines {
            if let item = parseMLSDLine(line) ?? parseUnixLine(line) {
                parsedAny = true
                if item.name != "." && item.name != ".." { items.append(item) }
            }
        }
        return parsedAny ? items : nil
    }

    private static func parseMLSDLine(_ line: String) -> MediaItem? {
        guard let separator = line.firstIndex(of: " ") else { return nil }
        let rawFacts = line[..<separator]
        guard rawFacts.hasSuffix(";") else { return nil }
        var facts: [String: String] = [:]
        for fact in rawFacts.split(separator: ";") {
            guard let equals = fact.firstIndex(of: "=") else { return nil }
            facts[String(fact[..<equals]).lowercased()] = String(fact[fact.index(after: equals)...])
        }
        guard let type = facts["type"]?.lowercased(), ["file", "dir", "cdir", "pdir"].contains(type) || type.hasPrefix("os.unix=slink") else { return nil }
        let name = String(line[line.index(after: separator)...])
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return nil }
        let size = max(0, Int64(facts["size"] ?? "0") ?? 0)
        let modified = facts["modify"].flatMap(ISODateParser.mlsdModify)
        let displayName = type == "cdir" ? "." : (type == "pdir" ? ".." : name)
        return MediaItem(id: displayName, name: displayName, isDirectory: ["dir", "cdir", "pdir"].contains(type), size: size, modifiedAt: modified)
    }

    private static func parseUnixLine(_ line: String) -> MediaItem? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 9, parts[0].count >= 10, parts[0].hasPrefix("-") || parts[0].hasPrefix("d") || parts[0].hasPrefix("l"),
              let size = Int64(parts[4]), size >= 0 else { return nil }
        let modified = ISODateParser.unixList(month: parts[5], day: parts[6], yearOrTime: parts[7])
        let name = parts.dropFirst(8).joined(separator: " ")
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return nil }
        return MediaItem(id: name, name: name, isDirectory: parts[0].hasPrefix("d"), size: size, modifiedAt: modified)
    }
}

/// Timeout, close and cancellation race NW callbacks; all share this one
/// exactly-once continuation gate. Cancellation before installation is kept.
private final class FTPContinuation<Value>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false
    private var result: Result<Value, Error>?
    private var timer: DispatchWorkItem?

    func install(_ continuation: CheckedContinuation<Value, Error>, deadline: Date,
                 cancel: @escaping () -> Void, operation: @escaping (@escaping (Result<Value, Error>) -> Void) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if finished { continuation.resume(with: result ?? .failure(CancellationError())); return }
        self.continuation = continuation
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.finish(.failure(FTPClient.FTPError.timeout)) else { return }
            cancel()
        }
        self.timer = timer
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { _ = finish(.failure(FTPClient.FTPError.timeout)); cancel(); return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining, execute: timer)
        operation { [weak self] result in _ = self?.finish(result) }
    }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        timer?.cancel()
        timer = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

private func ftpWait<Value>(deadline: Date, cancel: @escaping () -> Void,
                            operation: @escaping (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
    let once = FTPContinuation<Value>()
    return try await withTaskCancellationHandler(operation: {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            once.install(continuation, deadline: deadline, cancel: cancel, operation: operation)
        }
    }, onCancel: { if once.finish(.failure(CancellationError())) { cancel() } })
}

private final class FTPSession {
    private let connection: any FTPConnection
    private var buffer = Data()
    private var eof = false
    private let deadline: Date
    private let queue = DispatchQueue(label: "dev.brushllm.player.ftp", qos: .utility)
    private let controlHost: String
    private let factory: FTPClient.ConnectionFactory
    private let replyLimit = 1024 * 1024

    init(host: String, port: Int, timeout: TimeInterval, factory: @escaping FTPClient.ConnectionFactory) async throws {
        controlHost = host
        self.factory = factory
        deadline = Date().addingTimeInterval(timeout)
        let connection = factory(host, port)
        self.connection = connection
        do {
            let _: Void = try await ftpWait(deadline: deadline, cancel: { connection.cancel() }) {
                connection.start(queue: self.queue, completion: $0)
            }
        } catch { connection.cancel(); throw error }
    }

    func close() { connection.cancel() }

    func login(username: String, password: String) async throws {
        guard (try await command(nil)).hasPrefix("220") else { throw FTPClient.FTPError.connection("unexpected greeting") }
        let user = try await command("USER \(username)")
        if user.hasPrefix("230") { return }
        guard user.hasPrefix("331"), (try await command("PASS \(password)")).hasPrefix("230") else { throw FTPClient.FTPError.login }
    }

    @discardableResult
    func command(_ text: String?) async throws -> String {
        try Task.checkCancellation()
        if let text {
            guard !text.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 }) else { throw FTPClient.FTPError.badURL }
            let _: Void = try await ftpWait(deadline: deadline, cancel: { self.connection.cancel() }) {
                self.connection.send(Data((text + "\r\n").utf8), completion: $0)
            }
        }
        return try await readReply()
    }

    private func readReply() async throws -> String {
        let first = try await readLine()
        let bytes = Array(first.utf8)
        guard bytes.count >= 3, bytes.prefix(3).allSatisfy({ (48...57).contains($0) }) else { throw FTPClient.FTPError.connection("invalid reply") }
        guard bytes.count >= 4, bytes[3] == 45 else { return first }
        let code = String(first.prefix(3))
        var lines = [first]
        var count = first.utf8.count
        while true {
            let line = try await readLine()
            count += line.utf8.count
            guard count <= replyLimit else { throw FTPClient.FTPError.responseTooLarge }
            lines.append(line)
            if line == code || line.hasPrefix(code + " ") { return lines.joined(separator: "\n") }
        }
    }

    private func readLine() async throws -> String {
        while true {
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0 else { throw FTPClient.FTPError.timeout }
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let data = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                guard let line = String(data: data, encoding: .utf8) else { throw FTPClient.FTPError.connection("invalid reply encoding") }
                return line
            }
            guard !eof else { throw FTPClient.FTPError.connection("connection closed during reply") }
            let (chunk, done): (Data, Bool) = try await ftpWait(deadline: deadline, cancel: { self.connection.cancel() }) {
                self.connection.receive(maximumLength: 64 * 1024, completion: $0)
            }
            guard buffer.count + chunk.count <= replyLimit else { throw FTPClient.FTPError.responseTooLarge }
            buffer.append(chunk)
            eof = done
        }
    }

    func listDirectory(path: String) async throws -> String {
        guard (try await command("TYPE I")).hasPrefix("2") else { throw FTPClient.FTPError.listing }
        for verb in ["MLSD", "LIST"] {
            let pasv = try await command("PASV")
            guard pasv.hasPrefix("227"), let port = parsePASV(pasv) else { throw FTPClient.FTPError.connection("server does not support PASV") }
            // PASV addresses are hints (often a private/0.0.0.0 address), not
            // permission to connect to arbitrary third-party hosts.
            let data = try await FTPDataConnection(connection: factory(controlHost, port), deadline: deadline)
            defer { data.cancel() }
            let reply = try await command("\(verb) \(path)")
            if verb == "MLSD", reply.hasPrefix("5") { continue }
            if reply.hasPrefix("2") { return "" } // already-completed empty transfer
            guard reply.hasPrefix("1") else { throw FTPClient.FTPError.listing }
            let listing = try await data.readAll()
            let completion = try await command(nil)
            guard completion.hasPrefix("226") || completion.hasPrefix("250") else { throw FTPClient.FTPError.listing }
            return listing
        }
        throw FTPClient.FTPError.listing
    }

    private func parsePASV(_ reply: String) -> Int? {
        guard let open = reply.lastIndex(of: "("), let close = reply.lastIndex(of: ")"), open < close else { return nil }
        let fields = reply[reply.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 6 else { return nil }
        let numbers = fields.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let port = numbers[4] * 256 + numbers[5]
        return port == 0 ? nil : port
    }
}

private final class FTPDataConnection {
    private let connection: any FTPConnection
    private let deadline: Date
    private let queue = DispatchQueue(label: "dev.brushllm.player.ftp.data", qos: .utility)
    init(connection: any FTPConnection, deadline: Date) async throws {
        self.connection = connection
        self.deadline = deadline
        do {
            let _: Void = try await ftpWait(deadline: deadline, cancel: { connection.cancel() }) {
                connection.start(queue: self.queue, completion: $0)
            }
        } catch { connection.cancel(); throw error }
    }
    func cancel() { connection.cancel() }
    func readAll() async throws -> String {
        var data = Data()
        while true {
            try Task.checkCancellation()
            let (chunk, done): (Data, Bool) = try await ftpWait(deadline: deadline, cancel: { self.connection.cancel() }) {
                self.connection.receive(maximumLength: 256 * 1024, completion: $0)
            }
            guard data.count + chunk.count <= 16 * 1024 * 1024 else { throw FTPClient.FTPError.responseTooLarge }
            data.append(chunk)
            if done {
                guard let text = String(data: data, encoding: .utf8) else { throw FTPClient.FTPError.listing }
                return text
            }
        }
    }
}
