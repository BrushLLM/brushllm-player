import Foundation
import XCTest
@testable import BrushLLMPlayer

final class NetworkMemorySecretStore: SecretStore {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var rejectWrites = false
    var rejectDeletes = false
    var rejectedRead = false
    enum Failure: Error { case denied }
    private func key(_ account: String, _ service: String) -> String { service + "|" + account }
    func data(account: String, service: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if rejectedRead { throw Failure.denied }
        return values[key(account, service)]
    }
    func set(_ data: Data, account: String, service: String) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectWrites { throw Failure.denied }
        values[key(account, service)] = data
    }
    func delete(account: String, service: String) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectDeletes { throw Failure.denied }
        values.removeValue(forKey: key(account, service))
    }
}

final class NetworkStoreFixture {
    let suite = "dev.brushllm.player.tests." + UUID().uuidString
    let defaults: UserDefaults
    let secrets = NetworkMemorySecretStore()
    let store: MediaServerStore
    init() {
        defaults = UserDefaults(suiteName: suite)!
        store = MediaServerStore(defaults: defaults, secretStore: secrets)
    }
    deinit { defaults.removePersistentDomain(forName: suite) }
    func source(kind: MediaServerKind = .emby, base: String = "https://media.test", username: String = "alice") -> MediaServerSource {
        store.add(kind: kind, name: "Test", baseURL: base, username: username, password: "synthetic-password")!
    }
}

/// Every URLSession in these tests uses only this protocol, never real HTTP.
/// XCTest runs this target serially; handlers are additionally lock-protected.
final class NetworkURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (NetworkURLProtocol) -> Void
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var requests: [URLRequest] = []
    private static var stops = 0
    private static var bodies = 0
    private let instanceLock = NSLock()
    private var stopped = false

    static func install(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requests = []; stops = 0; bodies = 0
    }
    static func reset() { lock.lock(); handler = nil; lock.unlock() }
    static var recordedRequests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    static var bodyCount: Int { lock.lock(); defer { lock.unlock() }; return bodies }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        if let handler { handler(self) } else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    }
    override func stopLoading() {
        instanceLock.lock(); stopped = true; instanceLock.unlock()
        Self.lock.lock(); Self.stops += 1; Self.lock.unlock()
    }
    func respond(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    func headersOnly(status: Int = 200, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers.merging(["Content-Type": "video/mp4", "Content-Length": "1000000000"]) { old, _ in old })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // A server ignoring Range would continue delivering content. Cancel
        // must arrive before that callback, independently of the video size.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            instanceLock.lock(); let active = !stopped; instanceLock.unlock()
            guard active else { return }
            Self.lock.lock(); Self.bodies += 1; Self.lock.unlock()
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 4096))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class NetworkFakeFTPConnection: FTPConnection {
    typealias Chunk = (Data, Bool)
    var chunks: [Result<Chunk, Error>]
    var startSilently = false
    var silenceAfterChunks = false
    var sendError: Error?
    private(set) var commands: [String] = []
    private(set) var cancelCount = 0
    private var pending: ((Result<Chunk, Error>) -> Void)?
    private let lock = NSLock()
    init(_ replies: [String] = [], done: Bool = false) {
        chunks = replies.map { .success((Data($0.utf8), done)) }
    }
    func start(queue: DispatchQueue, completion: @escaping (Result<Void, Error>) -> Void) {
        if !startSilently { completion(.success(())); completion(.success(())) }
    }
    func send(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        commands.append(String(decoding: data, as: UTF8.self))
        let result: Result<Void, Error> = sendError.map { .failure($0) } ?? .success(())
        completion(result); completion(result)
    }
    func receive(maximumLength: Int, completion: @escaping (Result<Chunk, Error>) -> Void) {
        lock.lock()
        if !chunks.isEmpty {
            let result = chunks.removeFirst()
            lock.unlock()
            completion(result); completion(result)
        } else if silenceAfterChunks {
            pending = completion
            lock.unlock()
        } else {
            lock.unlock()
            completion(.success((Data(), true)))
        }
    }
    func cancel() {
        lock.lock(); cancelCount += 1; let pending = self.pending; self.pending = nil; lock.unlock()
        pending?(.failure(CancellationError()))
    }
}
