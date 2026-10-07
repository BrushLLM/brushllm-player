import Foundation
import XCTest
@testable import BrushLLMPlayer

final class NetworkWebDAVTests: XCTestCase {
    override func tearDown() { NetworkURLProtocol.reset(); super.tearDown() }
    private let source = MediaServerSource(kind: .webdav, name: "test", baseURL: "https://dav.test/dav", username: "alice")

    func testProbeCancelsIgnoredRangeBodyAndHandles206() async throws {
        for status in [200, 206] {
            NetworkURLProtocol.install { $0.headersOnly(status: status) }
            let session = NetworkURLProtocol.session()
            defer { session.invalidateAndCancel() }
            let url = try XCTUnwrap(WebDAVClient.playbackURL(source: source, path: "/dav/movie.mp4", password: "p"))
            let result = try await WebDAVClient.resolvePlaybackURL(url, source: source, password: "p", userAgent: "test-UA", session: session)
            XCTAssertEqual(result, url)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(NetworkURLProtocol.bodyCount, 0)
            XCTAssertGreaterThan(NetworkURLProtocol.stopCount, 0)
            XCTAssertEqual(NetworkURLProtocol.recordedRequests.first?.value(forHTTPHeaderField: "Range"), "bytes=0-0")
        }
    }

    func testRedirectChainDoesNotForwardCredentialsAcrossOrigin() async throws {
        NetworkURLProtocol.install { instance in
            let host = instance.request.url!.host!
            if host == "dav.test" { instance.headersOnly(status: 302, headers: ["Location": "https://cdn.test/first?signature=synthetic"]) }
            else if instance.request.url!.path == "/first" { instance.headersOnly(status: 307, headers: ["Location": "/final?signature=synthetic"]) }
            else { instance.headersOnly(status: 206) }
        }
        let session = NetworkURLProtocol.session()
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(WebDAVClient.playbackURL(source: source, path: "/dav/movie.mp4", password: "synthetic"))
        let final = try await WebDAVClient.resolvePlaybackURL(url, source: source, password: "synthetic", userAgent: "test-UA", session: session)
        XCTAssertEqual(final.absoluteString, "https://cdn.test/final?signature=synthetic")
        let requests = NetworkURLProtocol.recordedRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        for request in requests.dropFirst() {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.url?.user)
            XCTAssertNil(request.url?.password)
        }
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "test-UA" })
    }

    func testProbeRejectsDowngradeLoopUserInfoAndChainLimit() async throws {
        let session = NetworkURLProtocol.session()
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(WebDAVClient.playbackURL(source: source, path: "/dav/movie.mp4", password: "p"))
        for location in ["http://cdn.test/movie", "/dav/movie.mp4", "https://alice:p@cdn.test/movie"] {
            NetworkURLProtocol.install { $0.headersOnly(status: 302, headers: ["Location": location]) }
            do {
                _ = try await WebDAVClient.resolvePlaybackURL(url, source: source, password: "p", userAgent: nil, session: session)
                XCTFail("Unsafe redirect should not fall back to an unchecked mpv load")
            } catch {}
            XCTAssertEqual(NetworkURLProtocol.recordedRequests.count, 1)
        }
        NetworkURLProtocol.install { instance in
            let suffix = (Int(instance.request.url!.lastPathComponent) ?? 0) + 1
            instance.headersOnly(status: 302, headers: ["Location": "/\(suffix)"])
        }
        do {
            _ = try await WebDAVClient.resolvePlaybackURL(url, source: source, password: "p", userAgent: nil, session: session, maxRedirects: 2)
            XCTFail("Unbounded redirect chain")
        } catch {}
        XCTAssertEqual(NetworkURLProtocol.recordedRequests.count, 3)
        NetworkURLProtocol.install { $0.headersOnly(status: 401) }
        do {
            _ = try await WebDAVClient.resolvePlaybackURL(url, source: source, password: "p", userAgent: nil, session: session)
            XCTFail("HTTP auth failure must be reported")
        } catch {}
        XCTAssertEqual(NetworkURLProtocol.recordedRequests.count, 1)
    }

    func testSilentProbeHasDeadlineAndCancellation() async throws {
        NetworkURLProtocol.install { _ in }
        let session = NetworkURLProtocol.session()
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(WebDAVClient.playbackURL(source: source, path: "/dav/movie.mp4", password: "p"))
        let start = Date()
        do {
            _ = try await WebDAVClient.resolvePlaybackURL(url, source: source, password: "p", userAgent: nil, session: session, timeout: 0.05)
            XCTFail("Silent probe must time out")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let task = Task { try await WebDAVClient.resolvePlaybackURL(url, source: source, password: "p", userAgent: nil, session: session, timeout: 10) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Probe must honor cancellation")
        } catch {}
    }

    func testListingRequestsModifiedAndExcludesSelfByIdentity() async throws {
        NetworkURLProtocol.install { instance in
            XCTAssertEqual(instance.request.httpMethod, "PROPFIND")
            var body = instance.request.httpBody ?? Data()
            if let stream = instance.request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("getlastmodified"))
            let xml = "<multistatus xmlns=\"DAV:\"><response><href>/dav/one.mp4</href><propstat><prop><resourcetype/></prop><status>HTTP/1.1 200 OK</status></propstat></response><response><href>/dav/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>"
            instance.respond(status: 207, body: Data(xml.utf8))
        }
        let session = NetworkURLProtocol.session()
        defer { session.invalidateAndCancel() }
        let items = try await WebDAVClient.list(source: source, path: "/dav", password: "p", session: session)
        XCTAssertEqual(items.map(\.id), ["/dav/one.mp4"])
    }
}
