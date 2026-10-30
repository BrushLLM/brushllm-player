import Foundation

/// Open Subtitles (opensubtitles.com) client, ported from IINA's
/// `OpenSubClient` + `OpenSub` fetcher (GPL). IINA's client is built on
/// Just/PromiseKit; this port uses URLSession async/await.
///
/// REST API: https://opensubtitles.stoplight.io/docs/opensubtitles-api
/// - Every request carries the `Api-Key` header (IINA's public GPL key,
///   stored reversed exactly as in IINA and reversed again when sent) and a
///   `User-Agent` identifying the app.
/// - A logged-in session adds `Authorization: Bearer <JWT>`; search also
///   works anonymously without it (IINA's behavior: no account configured
///   means anonymous search).
/// - The token is cached in memory only, valid for the app session (IINA
///   persists credentials in the Keychain; V1 ships no login UI, so there
///   is nothing to persist).
actor OpenSubtitles {

  /// The shared client object (IINA: `OpenSubClient.shared`).
  static let shared = OpenSubtitles()

  // MARK: - Errors

  enum Error: Swift.Error {
    /// A REST API call failed (IINA: `callFailed`).
    case callFailed(statusCode: Int?, message: String?)
    /// The HTTP response was expected to contain content, but had none
    /// (IINA: `contentMissing`).
    case contentMissing(statusCode: Int?)
    /// The API returned a JSON error body (IINA: `errorResponse`).
    case errorResponse(message: String)
    /// The downloaded subtitle file has zero length (IINA: `emptyFile`).
    case emptyFile(String)
    /// A downloaded zip archive contained no subtitle file.
    case archiveHasNoSubtitle
    /// The subtitle result has no file to download.
    case noFile
  }

  // MARK: - Constants (IINA OpenSubClient)

  /// URL prepended to a REST method name to form the endpoint.
  /// Open Subtitles may redirect the client to a different host after login
  /// (IINA: `apiBaseURL` / `apiDefaultHostname`).
  private var apiBaseURL: URL

  private let apiDefaultHostname = "api.opensubtitles.com"

  /// Official IINA Open Subtitles API key — public, shipped in IINA's GPL
  /// source. The key identifies the *application*, not the user. Stored
  /// reversed exactly as IINA stores it, and reversed again when sent
  /// (IINA: `apiKey` + `formHeaders`).
  private let apiKey = "SPX87dlUuuHpxeh5u3rd7dHekOT6oYpx"

  /// Value for the `User-Agent` header. IINA sends "IINA v<version>"; this
  /// port sends "BrushLLMPlayer/<version>".
  private static let userAgent = "BrushLLMPlayer/"
    + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.8")

  /// Length of time a JWT is considered valid. Open Subtitles expires user
  /// sessions after 24 hours; the client expires them after 23 to reduce
  /// the chance of a 406 "invalid token" failure (IINA: `tokenLifetime`).
  private let tokenLifetime: TimeInterval = 23 * 60 * 60

  /// Open Subtitles hash chunk size (IINA: `chunkSize`).
  private static let chunkSize = 65536

  /// Minimum file size Open Subtitles supports for hashing: two chunks
  /// (IINA: `minimumFileSize`, 131072 bytes).
  private static let minimumFileSize = 131072

  /// Ephemeral session: no on-disk caching of API responses.
  private let session = URLSession(configuration: .ephemeral)

  /// JSON decoder configured for the API: snake_case keys and ISO 8601
  /// dates with or without fractional seconds (IINA: `decoder`).
  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let iso8601 = ISO8601DateFormatter()
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withFractionalSeconds]
      let container = try decoder.singleValueContainer()
      let dateStr = try container.decode(String.self)
      if let date = iso8601.date(from: dateStr) { return date }
      if let date = fractional.date(from: dateStr) { return date }
      throw DecodingError.dataCorruptedError(in: container,
                                             debugDescription: "Expected ISO 8601 date: \(dateStr)")
    }
    return decoder
  }()

  // MARK: - State

  /// Authorization JWT returned by login; nil = anonymous (IINA: `token`).
  private var token: String?

  /// Time when the JWT will be considered expired (IINA: `tokenExpiration`).
  private var tokenExpiration: Date?

  /// Rate-limit quota tracking (IINA: `RateLimiter`). Open Subtitles allows
  /// 5 requests/second and reports the remaining quota in `RateLimit-*`
  /// response headers; the client waits before the next call when the
  /// quota for the current window is exhausted.
  private var rateRemaining = Int.max
  private var rateReset: TimeInterval = 0

  /// True when the client holds an unexpired JWT (IINA: `loggedIn`).
  var loggedIn: Bool {
    guard let token, let tokenExpiration = tokenExpiration else { return false }
    guard Date() < tokenExpiration else {
      DebugLog.log("opensubtitles: user session has expired")
      abandonUserSession()
      return false
    }
    return true
  }

  private init() {
    apiBaseURL = OpenSubtitles.formBaseURL(hostname: apiDefaultHostname)!
  }

  // MARK: - REST API Methods

  /// Performs a request and returns the body plus the typed HTTP response,
  /// recording the server's rate-limit headers.
  private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw Error.callFailed(statusCode: nil, message: "not an HTTP response")
    }
    processRateLimitHeaders(http)
    return (data, http)
  }

  /// [Login](https://opensubtitles.stoplight.io/docs/opensubtitles-api/73acf79accc0a-login).
  /// Returns a JWT that is then sent in an `Authorization` header. Based on
  /// account privileges the server may direct the client to a different
  /// host for further requests. V1 has no login UI; the method exists so a
  /// future settings tab can enable it (IINA: `login(username:password:)`).
  func login(username: String, password: String) async throws -> LoginResponse {
    try await delayBeforeCall()
    var request = URLRequest(url: apiURL("login"))
    request.httpMethod = "POST"
    applyHeaders(to: &request)
    request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
    let (data, http) = try await send(request)
    let response = try decodeResponse(LoginResponse.self, from: data, http: http)
    token = response.token
    tokenExpiration = Date().addingTimeInterval(tokenLifetime)
    if let hostname = response.baseUrl, let baseURL = OpenSubtitles.formBaseURL(hostname: hostname) {
      apiBaseURL = baseURL
    }
    DebugLog.log("opensubtitles: logged in")
    return response
  }

  /// [Logout](https://opensubtitles.stoplight.io/docs/opensubtitles-api/9fe4d6d078e50-logout).
  /// The session is abandoned whether or not the request succeeds
  /// (IINA: `logout`).
  func logout() async {
    guard token != nil else { return }
    try? await delayBeforeCall()
    var request = URLRequest(url: apiURL("logout"))
    request.httpMethod = "DELETE"
    applyHeaders(to: &request)
    _ = try? await send(request)
    abandonUserSession()
    DebugLog.log("opensubtitles: logged out")
  }

  /// [Subtitles](https://opensubtitles.stoplight.io/docs/opensubtitles-api/a172317bd5ccc-search-for-subtitles).
  /// Find subtitles matching the query and hash (if available) in the given
  /// languages. When a hash is provided, exact hash matches are returned
  /// first (IINA: `subtitles(languages:hash:query:)`).
  /// - Returns: results of type "subtitle" that have at least one file
  ///   (IINA validates both after decoding).
  func search(languages: [String], hash: String?, query: String?) async throws -> [Subtitle] {
    try await delayBeforeCall()
    var components = URLComponents(url: apiURL("subtitles"), resolvingAgainstBaseURL: false)!
    // Parameters in alphabetical order per API best practices.
    var items = [URLQueryItem(name: "languages", value: languages.sorted().joined(separator: ","))]
    if let hash { items.append(URLQueryItem(name: "moviehash", value: hash)) }
    if let query { items.append(URLQueryItem(name: "query", value: query)) }
    components.queryItems = items
    var request = URLRequest(url: components.url!)
    applyHeaders(to: &request)
    let (data, http) = try await send(request)
    let response = try decodeResponse(SubtitlesResponse.self, from: data, http: http)
    return response.data.filter { $0.type == "subtitle" && !$0.attributes.files.isEmpty }
  }

  /// [Download](https://opensubtitles.stoplight.io/docs/opensubtitles-api/6be7f6ae2d918-download).
  /// This does NOT return the file contents — it returns a temporary link
  /// plus download-quota information; `downloadFileContents` fetches the
  /// actual bytes (IINA: `download(fileId:)`).
  func download(fileId: Int) async throws -> DownloadResponse {
    try await delayBeforeCall()
    var request = URLRequest(url: apiURL("download"))
    request.httpMethod = "POST"
    applyHeaders(to: &request)
    request.httpBody = try JSONEncoder().encode(["file_id": fileId])
    let (data, http) = try await send(request)
    return try decodeResponse(DownloadResponse.self, from: data, http: http)
  }

  /// Fetches the contents of a subtitle file via the link returned by
  /// `download(fileId:)` (IINA: `downloadFileContents(_:)`).
  func downloadFileContents(_ url: URL) async throws -> Data {
    try await delayBeforeCall()
    var request = URLRequest(url: url)
    applyHeaders(to: &request)
    let (data, http) = try await send(request)
    guard (200..<300).contains(http.statusCode) else {
      // On download failures Open Subtitles returns a plain-text message or
      // an HTML error page rather than the REST API's JSON error body.
      if let text = String(data: data, encoding: .utf8) {
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/html") {
          throw formErrorIfHtml(text, statusCode: http.statusCode)
        }
        throw Error.callFailed(statusCode: http.statusCode, message: String(text.prefix(200)))
      }
      throw Error.callFailed(statusCode: http.statusCode, message: nil)
    }
    return data
  }

  /// Full download flow for one search result (IINA:
  /// `OpenSub.Subtitle.download`): request the temporary link, fetch the
  /// contents, write them to a temp file and return its URL for `sub-add`.
  /// A zip archive (some results bundle several files) is extracted with
  /// `/usr/bin/unzip` and the first subtitle file is returned.
  func downloadSubtitleFile(_ subtitle: Subtitle) async throws -> URL {
    guard let fileId = subtitle.attributes.files.first?.fileId else { throw Error.noFile }
    let response = try await download(fileId: fileId)
    let data = try await downloadFileContents(response.link)
    // Open Subtitles has returned zero-length subtitle files; catch that
    // here rather than letting mpv fail on an empty file (IINA: `emptyFile`).
    guard !data.isEmpty else {
      throw Error.emptyFile(response.fileName ?? "subtitle \(fileId) is empty, no contents")
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BrushLLMPlayer-Subtitles-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    if OpenSubtitles.isZip(data) {
      return try OpenSubtitles.extractSubtitle(fromZip: data, in: directory)
    }
    let name = OpenSubtitles.sanitizeFileName(
      response.fileName ?? subtitle.attributes.files.first?.fileName ?? "subtitle.srt")
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    DebugLog.log("opensubtitles: downloaded \(name) (quota remaining: \(response.remaining ?? -1))")
    return url
  }

  // MARK: - Hash (IINA OpenSub.Fetcher.hash)

  /// The classic Open Subtitles hash: the first and last 64 KiB of the file
  /// summed as little-endian 64-bit words, plus the file size, formatted as
  /// 16 hex digits. Providing it when searching makes the API rank exact
  /// matches first. Returns nil when hashing is impossible (streaming,
  /// unreadable, or smaller than Open Subtitles' 131072-byte minimum) —
  /// the caller then falls back to a name-only search.
  ///
  /// Algorithm: https://trac.opensubtitles.org/projects/opensubtitles/wiki/HashSourceCodes
  static func hash(url: URL) -> String? {
    guard url.isFileURL, let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { file.closeFile() }
    file.seekToEndOfFile()
    let fileSize = file.offsetInFile
    guard fileSize > UInt64(minimumFileSize) else { return nil }
    var hash: UInt64 = 0
    for offset: UInt64 in [0, fileSize - UInt64(chunkSize)] {
      file.seek(toFileOffset: offset)
      hash = hash &+ chksum64(file.readData(ofLength: chunkSize))
    }
    hash &+= fileSize
    return String(format: "%016qx", hash)
  }

  /// Sums the data as a sequence of little-endian 64-bit words
  /// (IINA: `Data.chksum64`).
  private static func chksum64(_ data: Data) -> UInt64 {
    data.withUnsafeBytes { $0.bindMemory(to: UInt64.self).reduce(0, &+) }
  }

  // MARK: - Supporting Methods

  /// Discards the JWT and resets the API host to the default server
  /// (IINA: `abandonUserSession`).
  private func abandonUserSession() {
    apiBaseURL = OpenSubtitles.formBaseURL(hostname: apiDefaultHostname)!
    token = nil
    tokenExpiration = nil
  }

  /// The REST API endpoint for `method` (IINA: `apiURL`).
  private func apiURL(_ method: String) -> URL {
    URL(string: method, relativeTo: apiBaseURL)!
  }

  /// Base URL for API requests against the given host (IINA:
  /// `formBaseURL(hostname:)`).
  private static func formBaseURL(hostname: String) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = hostname
    components.path = "/api/v1/"
    return components.url
  }

  /// The headers sent in every request: the API key, the User-Agent and —
  /// when logged in — the Bearer token (IINA: `formHeaders`). Anonymous
  /// requests simply omit `Authorization`.
  private func applyHeaders(to request: inout URLRequest) {
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.setValue(String(apiKey.reversed()), forHTTPHeaderField: "Api-Key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(OpenSubtitles.userAgent, forHTTPHeaderField: "User-Agent")
    if let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
  }

  /// Waits before a call when the current rate-limit window's quota is
  /// exhausted (IINA: `RateLimiter.delayBeforeCall`).
  private func delayBeforeCall() async throws {
    let now = Date().timeIntervalSince1970
    guard rateReset > now else { return }
    rateRemaining -= 1
    guard rateRemaining < 0 else { return }
    let delay = (rateReset - now).rounded(.up)
    DebugLog.log("opensubtitles: rate limit quota reached, waiting \(delay)s")
    try await Task.sleep(for: .seconds(delay))
  }

  /// Records the quota reported in `RateLimit-*` response headers
  /// (IINA: `RateLimiter.processRateLimitHeaders`). Malformed values are
  /// ignored, as the draft RFC requires.
  private func processRateLimitHeaders(_ http: HTTPURLResponse) {
    guard let remainingText = http.value(forHTTPHeaderField: "ratelimit-remaining"),
          let resetText = http.value(forHTTPHeaderField: "ratelimit-reset"),
          let remaining = Int(remainingText), remaining >= 0,
          let reset = Int(resetText), reset >= 0 else { return }
    rateReset = Date().timeIntervalSince1970 + Double(reset)
    rateRemaining = remaining
  }

  /// Decodes a REST API response, mapping failures onto `Error`
  /// (IINA: `decodeResponse`). Non-2xx responses carry a JSON error body,
  /// except certain failures that return an HTML error page instead.
  private func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data,
                                           http: HTTPURLResponse) throws -> T {
    guard (200..<300).contains(http.statusCode) else {
      if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/html"),
         let text = String(data: data, encoding: .utf8) {
        throw formErrorIfHtml(text, statusCode: http.statusCode)
      }
      if let error = try? Self.decoder.decode(ErrorResponse.self, from: data) {
        throw Error.errorResponse(message: error.message)
      }
      throw Error.callFailed(statusCode: http.statusCode,
                             message: String(data: data.prefix(256), encoding: .utf8))
    }
    guard !data.isEmpty else { throw Error.contentMissing(statusCode: http.statusCode) }
    do {
      return try Self.decoder.decode(T.self, from: data)
    } catch {
      DebugLog.log("opensubtitles: decoding \(String(describing: type)) failed: \(error)")
      throw error
    }
  }

  /// Builds an error from an HTML error page's `<title>` (IINA:
  /// `formErrorIfHtmlResponse`).
  private func formErrorIfHtml(_ text: String, statusCode: Int) -> Error {
    guard let start = text.range(of: "<title>"), let end = text.range(of: "</title>"),
          start.upperBound < end.lowerBound else {
      return .callFailed(statusCode: statusCode, message: "HTML returned instead of JSON")
    }
    var message = String(text[start.upperBound..<end.lowerBound])
    let prefix = "\(statusCode) "
    if message.hasPrefix(prefix) { message = String(message.dropFirst(prefix.count)) }
    return .callFailed(statusCode: statusCode, message: message)
  }

  // MARK: - Download helpers

  /// A zip archive starts with the "PK\x03\x04" magic bytes.
  private static func isZip(_ data: Data) -> Bool {
    data.count > 4 && Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04]
  }

  /// Extracts a downloaded zip into `directory` and returns the first
  /// subtitle file, preferring common single-file formats (.srt first).
  private static func extractSubtitle(fromZip data: Data, in directory: URL) throws -> URL {
    let zipURL = directory.appendingPathComponent("download.zip")
    try data.write(to: zipURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-o", zipURL.path, "-d", directory.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    try? FileManager.default.removeItem(at: zipURL)
    guard process.terminationStatus == 0 else {
      throw Error.callFailed(statusCode: nil, message: "unzip failed (\(process.terminationStatus))")
    }
    let extensions = ["srt", "ass", "ssa", "sub", "vtt", "sup", "idx"]
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)) ?? []
    for ext in extensions {
      if let hit = contents.first(where: { $0.pathExtension.lowercased() == ext }) {
        DebugLog.log("opensubtitles: extracted \(hit.lastPathComponent) from zip")
        return hit
      }
    }
    throw Error.archiveHasNoSubtitle
  }

  /// Keeps only the last path component of a server-provided file name.
  private static func sanitizeFileName(_ name: String) -> String {
    let cleaned = name.split(separator: "/").last.map(String.init) ?? name
    return cleaned.isEmpty ? "subtitle.srt" : cleaned
  }

  // MARK: - Response Models (IINA OpenSubClient models)

  /// Response returned by the login method (IINA: `LoginResponse`).
  struct LoginResponse: Decodable {
    var baseUrl: String?
    var status: Int?
    var token: String
    var user: User?

    struct User: Decodable {
      var allowedDownloads: Int?
      var level: String?
      var userId: Int?
      var vip: Bool?
    }
  }

  /// Response returned by the subtitles search (IINA: `SubtitlesResponse`).
  struct SubtitlesResponse: Decodable {
    var data: [Subtitle]
    var page: Int?
    var perPage: Int?
    var totalCount: Int?
    var totalPages: Int?
  }

  /// One subtitle search result (IINA: `OpenSubClient.Subtitle`). Fields
  /// the REST API documents as required have proven unreliable in
  /// practice, so everything except the identity and file list is decoded
  /// as optional.
  struct Subtitle: Decodable, Identifiable, Sendable {
    var id: String
    var type: String
    var attributes: SubtitleAttributes

    struct SubtitleAttributes: Decodable, Sendable {
      var downloadCount: Int?
      var featureDetails: SubtitleFeatureDetails
      var files: [SubtitleFile]
      var fps: Double?
      var language: String
      var ratings: Double?
      var uploadDate: Date?

      /// Details about the media the subtitles are for. The JSON is
      /// dynamically typed (movie/tvshow/episode); only the common
      /// properties are modeled (IINA: `SubtitleFeatureDetails`).
      struct SubtitleFeatureDetails: Decodable, Sendable {
        var featureId: Int?
        var featureType: String?
        var imdbId: Int?
        var title: String
        var tmdbId: Int?
        var year: Int?
      }

      struct SubtitleFile: Decodable, Sendable {
        var fileId: Int
        var fileName: String
      }
    }
  }

  /// Response returned by the download method (IINA: `DownloadResponse`).
  struct DownloadResponse: Decodable {
    var fileName: String?
    var link: URL
    var message: String?
    var remaining: Int?
    var requests: Int?
    var resetTime: String?
    var resetTimeUtc: Date?
  }

  /// JSON error body returned by failed API calls (IINA: `ErrorResponse`).
  struct ErrorResponse: Decodable {
    var message: String
    var remaining: Int?
    var requests: Int?
    var resetTime: String?
    var resetTimeUtc: Date?
  }
}

// MARK: - Error descriptions (IINA OpenSubClient.Error extension)

extension OpenSubtitles.Error: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .callFailed(let statusCode, let message):
      if let message, let statusCode {
        return "\(message) (\(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode)))"
      }
      if let message { return message }
      if let statusCode {
        return "\(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))"
      }
      return String(describing: self)
    case .contentMissing(let statusCode):
      let message = "Response content is missing"
      guard let statusCode else { return message }
      return "\(message) (\(statusCode))"
    case .errorResponse(let message):
      return message
    case .emptyFile(let reason):
      return "Invalid file, \(reason)"
    case .archiveHasNoSubtitle:
      return "The downloaded archive contains no subtitle file"
    case .noFile:
      return "The subtitle has no file to download"
    }
  }
}
