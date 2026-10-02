import Foundation
import Network

/// FTP client. Directory listing is implemented directly over
/// Network.framework (USER/PASS → TYPE I → PASV → MLSD, falling back to
/// LIST); playback uses ffmpeg's native ftp:// protocol with credentials
/// embedded in the URL (same approach as WebDAV).
enum FTPClient {

    enum FTPError: LocalizedError {
        case badURL
        case connection(String)
        case login
        case listing

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid FTP URL"
            case .connection(let detail): return "Could not connect: \(detail)"
            case .login: return "Login failed — check username and password"
            case .listing: return "Could not read the directory listing"
            }
        }
    }

    // MARK: - Browsing

    /// Lists a directory. `path` is the absolute server path ("/" = root).
    /// Item ids are absolute paths so they work as browse cursors directly.
    static func list(source: MediaServerSource, path: String, password: String?) async throws -> [MediaItem] {
        guard let components = URLComponents(string: source.baseURL),
              let host = components.host else { throw FTPError.badURL }
        let port = components.port ?? 21
        let username = source.username.isEmpty ? "anonymous" : source.username
        let pass = password ?? ""

        let session = try await FTPSession(host: host, port: port)
        defer { session.close() }
        try await session.login(username: username, password: pass)
        let raw = try await session.listDirectory(path: path)

        guard let parsed = parseListing(raw) else { throw FTPError.listing }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        // Drop the "." and ".." entries some servers return; ids become
        // absolute paths.
        return parsed
            .filter { $0.name != "." && $0.name != ".." }
            .map { MediaItem(id: prefix + $0.name, name: $0.name, isDirectory: $0.isDirectory, size: $0.size) }
    }

    /// The root path: the path part of the base URL ("/" by default).
    static func rootPath(of source: MediaServerSource) -> String {
        guard let components = URLComponents(string: source.baseURL) else { return "/" }
        var path = components.path
        if !path.hasPrefix("/") { path = "/" + path }
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    // MARK: - Playback

    /// ftp:// URL with embedded credentials for ffmpeg's native protocol.
    static func playbackURL(source: MediaServerSource, path: String, password: String?) -> URL? {
        guard var components = URLComponents(string: source.baseURL) else { return nil }
        let username = source.username.isEmpty ? "anonymous" : source.username
        components.user = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
        components.password = (password ?? "").addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed)
        let normalized = path.hasPrefix("/") ? path : "/" + path
        components.path = normalized
        return components.url
    }

    // MARK: - Listing parsing

    /// Parses MLSD lines (`fact=value;... name`) or classic unix LIST lines
    /// (`drwxr-xr-x ... size date name`).
    static func parseListing(_ raw: String) -> [MediaItem]? {
        // Servers use \r\n, \n or (rarely) bare \r line endings.
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var items: [MediaItem] = []
        var parsedAny = false
        for line in lines where !line.isEmpty {
            if let item = parseMLSDLine(line) ?? parseUnixLine(line) {
                items.append(item)
                parsedAny = true
            }
        }
        return parsedAny ? items : nil
    }

    /// MLSD: `type=dir;size=0; name` (facts separated by ";").
    private static func parseMLSDLine(_ line: String) -> MediaItem? {
        guard line.contains("=") else { return nil }
        var facts: [String: String] = [:]
        var rest = Substring(line)
        while let semicolon = rest.firstIndex(of: ";") {
            let fact = rest[..<semicolon]
            rest = rest[rest.index(after: semicolon)...]
            guard let equals = fact.firstIndex(of: "=") else { continue }
            facts[String(fact[..<equals])] = String(fact[fact.index(after: equals)...])
            // Facts end when the remainder starts with a space.
            if rest.hasPrefix(" ") { rest = rest.dropFirst(); break }
        }
        guard !rest.isEmpty else { return nil }
        let name = String(rest)
        let type = facts["type"] ?? ""
        let isDirectory = type == "dir" || type == "cdir" || type == "pdir"
        let size = Int64(facts["size"] ?? "0") ?? 0
        guard type != "cdir" && type != "pdir" else { return nil }
        return MediaItem(id: name, name: name, isDirectory: isDirectory, size: size)
    }

    /// Classic unix LIST: `drwxr-xr-x 1 owner group 4096 Jan 1 12:00 name`.
    private static func parseUnixLine(_ line: String) -> MediaItem? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 9, parts[0].count >= 10,
              parts[0].hasPrefix("-") || parts[0].hasPrefix("d") || parts[0].hasPrefix("l") else { return nil }
        let isDirectory = parts[0].hasPrefix("d")
        let size = Int64(parts[4]) ?? 0
        // The file name is everything after the 8th column (may contain spaces).
        let nameParts = parts.dropFirst(8)
        let name = nameParts.joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return MediaItem(id: name, name: name, isDirectory: isDirectory, size: size)
    }
}

// MARK: - Minimal FTP session over NWConnection


/// Resumes a continuation exactly once from any thread (NWConnection state
/// handlers run on the connection's queue, but Swift's concurrency checking
/// cannot prove exclusivity for captured vars).
private final class ResumeOnce {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<Void, Error>, throwing error: Error?) {
        lock.lock()
        let already = done
        done = true
        lock.unlock()
        guard !already else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

/// A single-connection FTP control channel: sequential command/response
/// with PASV data connections for listings.
private final class FTPSession {
    private let connection: NWConnection
    private var buffer = Data()
    private let queue = DispatchQueue(label: "dev.brushllm.player.ftp")
    /// Servers behind NAT advertise 0.0.0.0 in PASV replies; data
    /// connections must go to the control connection's host instead.
    private let controlHost: String

    init(host: String, port: Int) async throws {
        controlHost = host
        // NWConnection's async establishment via a continuation wrapper.
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port))!, using: .tcp)
        self.connection = conn
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(continuation, throwing: nil)
                case .failed(let error):
                    once.resume(continuation, throwing: error)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    func close() {
        // Best-effort QUIT; the connection closes regardless.
        send("QUIT")
        connection.cancel()
    }

    // MARK: - Commands

    func login(username: String, password: String) async throws {
        let welcome = try await command(nil) // 220 greeting
        guard welcome.hasPrefix("220") else { throw FTPClient.FTPError.connection("unexpected greeting \(welcome.prefix(3))") }
        let userReply = try await command("USER \(username)")
        if userReply.hasPrefix("230") {
            return // logged in without a password
        }
        guard userReply.hasPrefix("331") else { throw FTPClient.FTPError.login }
        let passReply = try await command("PASS \(password)")
        guard passReply.hasPrefix("230") else { throw FTPClient.FTPError.login }
    }

    /// Sends a command and awaits its complete response. FTP replies may
    /// span multiple lines: `XXX-` starts a block that runs until a `XXX `
    /// line with the same code.
    @discardableResult
    func command(_ command: String?) async throws -> String {
        if let command {
            send(command)
        }
        return try await readReply()
    }

    /// Reads one complete reply (multi-line aware).
    private func readReply() async throws -> String {
        let first = try await readLine()
        var lines = [first]
        // A valid reply starts with three digits; a dash right after them
        // opens a multi-line block.
        guard first.count >= 4 else { return first }
        let code = first.prefix(3)
        guard code.allSatisfy(\.isNumber), first[first.index(first.startIndex, offsetBy: 3)] == "-" else {
            return first
        }
        while true {
            let line = try await readLine()
            lines.append(line)
            // The block ends at "XXX " (or a bare "XXX") with the same code.
            if line.hasPrefix(code) && (line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " ") {
                return lines.joined(separator: "\n")
            }
        }
    }

    private func send(_ command: String) {
        let data = Data((command + "\r\n").utf8)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func readLine() async throws -> String {
        while true {
            if let line = takeLineFromBuffer() { return line }
            try await waitForData()
        }
    }

    private func takeLineFromBuffer() -> String? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        let lineData = buffer[buffer.startIndex..<range.lowerBound]
        let line = String(data: Data(lineData), encoding: .utf8) ?? ""
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return line
    }

    private func waitForData() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    self.buffer.append(content)
                    continuation.resume()
                } else if isComplete {
                    continuation.resume(throwing: FTPClient.FTPError.connection("connection closed"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Data connection (PASV)

    /// Lists a directory over a PASV data connection. Tries MLSD first,
    /// falls back to LIST when the server rejects it.
    func listDirectory(path: String) async throws -> String {
        try await command("TYPE I")
        let pasvReply = try await command("PASV")
        guard pasvReply.hasPrefix("227"), let (pasvHost, port) = parsePASV(pasvReply) else {
            throw FTPClient.FTPError.connection("server does not support PASV")
        }
        let host = dataHost(pasvHost)

        // Open the data connection before issuing the list command.
        let data = try await DataConnection(host: host, port: port)

        let mlsdReply = try await command("MLSD \(path)")
        if mlsdReply.hasPrefix("5") {
            // Server doesn't know MLSD — drop this data connection and retry
            // with LIST on a fresh one.
            data.cancel()
            let pasv2 = try await command("PASV")
            guard pasv2.hasPrefix("227"), let (pasvHost2, port2) = parsePASV(pasv2) else {
                throw FTPClient.FTPError.connection("server does not support PASV")
            }
            let data2 = try await DataConnection(host: dataHost(pasvHost2), port: port2)
            let listReply = try await command("LIST \(path)")
            guard listReply.hasPrefix("1") || listReply.hasPrefix("2") else {
                data2.cancel()
                throw FTPClient.FTPError.listing
            }
            let raw = try await data2.readAll()
            _ = try? await command(nil) // 226 transfer complete
            return raw
        }
        guard mlsdReply.hasPrefix("1") || mlsdReply.hasPrefix("2") else {
            data.cancel()
            throw FTPClient.FTPError.listing
        }
        let raw = try await data.readAll()
        _ = try? await command(nil) // 226 transfer complete
        return raw
    }

    /// NAT'd servers advertise 0.0.0.0 (or the control host itself) in PASV
    /// replies; the data connection goes to the control connection's host.
    private func dataHost(_ pasvHost: String) -> String {
        if pasvHost == "0.0.0.0" || pasvHost.isEmpty { return controlHost }
        return pasvHost
    }

    /// Parses "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)".
    private func parsePASV(_ reply: String) -> (String, Int)? {
        guard let open = reply.lastIndex(of: "("), let close = reply.lastIndex(of: ")"),
              open < close else { return nil }
        let numbers = reply[reply.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6 else { return nil }
        let host = numbers[0...3].map(String.init).joined(separator: ".")
        let port = numbers[4] * 256 + numbers[5]
        return (host, port)
    }
}

/// A one-shot PASV data connection that reads until EOF.
private final class DataConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.brushllm.player.ftp.data")

    init(host: String, port: Int) async throws {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port))!, using: .tcp)
        self.connection = conn
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(continuation, throwing: nil)
                case .failed(let error):
                    once.resume(continuation, throwing: error)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    func cancel() {
        connection.cancel()
    }

    func readAll() async throws -> String {
        var data = Data()
        while true {
            let (chunk, done) = try await receiveChunk()
            data.append(chunk)
            if done {
                connection.cancel()
                return String(data: data, encoding: .utf8) ?? ""
            }
        }
    }

    private func receiveChunk() async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (content ?? Data(), isComplete))
                }
            }
        }
    }
}
