import Foundation
import XCTest
@testable import BrushLLMPlayer

final class NetworkEmbyTests: XCTestCase {
    override func tearDown() { NetworkURLProtocol.reset(); super.tearDown() }

    func test401AuthenticatesOnlyOnceAndPrefixAppliesToAllEndpoints() async throws {
        let fixture = NetworkStoreFixture()
        let source = fixture.source()
        var authCount = 0
        var browseCount = 0
        NetworkURLProtocol.install { instance in
            let path = instance.request.url!.path
            if path == "/Users/AuthenticateByName" { instance.respond(status: 404); return }
            if path == "/emby/Users/AuthenticateByName" {
                authCount += 1
                instance.respond(body: Data("{\"AccessToken\":\"token-\(authCount)\",\"User\":{\"Id\":\"user\"}}".utf8))
                return
            }
            XCTAssertEqual(path, "/emby/Users/user/Items")
            browseCount += 1
            if browseCount == 1 { instance.respond(status: 401) }
            else { instance.respond(body: Data("{\"Items\":[{\"Id\":\"track\",\"Name\":\"Music\",\"Type\":\"Audio\",\"Size\":100000000}]}".utf8)) }
        }
        let network = NetworkURLProtocol.session()
        defer { network.invalidateAndCancel() }
        let items = try await EmbyClient.list(source: source, parentID: "", password: "p", store: fixture.store, network: network)
        XCTAssertEqual(authCount, 2)
        XCTAssertEqual(browseCount, 2)
        let url = await EmbyClient.playbackURL(source: source, item: try XCTUnwrap(items.first), password: "p", store: fixture.store, network: network)
        XCTAssertEqual(url?.path, "/emby/Audio/track/universal")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "api_key" })?.value, "token-2")
        XCTAssertEqual(NetworkURLProtocol.recordedRequests.filter { $0.url?.path == "/Users/AuthenticateByName" }.count, 1)
    }

    func testRepeated401IsBoundedAndUnknownMediaCannotPlay() async throws {
        let fixture = NetworkStoreFixture()
        let source = fixture.source()
        var authCount = 0
        NetworkURLProtocol.install { instance in
            if instance.request.url!.path.hasSuffix("AuthenticateByName") {
                authCount += 1
                instance.respond(body: Data("{\"AccessToken\":\"token\",\"User\":{\"Id\":\"user\"}}".utf8))
            } else { instance.respond(status: 401) }
        }
        let network = NetworkURLProtocol.session()
        defer { network.invalidateAndCancel() }
        do { _ = try await EmbyClient.list(source: source, parentID: "", password: "p", store: fixture.store, network: network); XCTFail("Expected authentication failure") }
        catch { XCTAssertEqual(error as? EmbyClient.EmbyError, .auth) }
        XCTAssertEqual(authCount, 2)
        XCTAssertEqual(NetworkURLProtocol.recordedRequests.count, 4)
        let unknown = MediaItem(id: "unknown", name: "not-really.mp4", isDirectory: false, size: 1)
        let url = await EmbyClient.playbackURL(source: source, item: unknown, password: "p", store: fixture.store, network: network)
        XCTAssertNil(url)
        XCTAssertEqual(NetworkURLProtocol.recordedRequests.count, 4)
    }

    func testHostAccountChangesDoNotSendOldTokenAndExplicitPrefixIsNotDuplicated() async throws {
        let fixture = NetworkStoreFixture()
        var source = fixture.source(base: "https://old.test/emby")
        var authCount = 0
        NetworkURLProtocol.install { instance in
            if instance.request.url!.path.hasSuffix("AuthenticateByName") {
                authCount += 1
                XCTAssertEqual(instance.request.url!.path, "/emby/Users/AuthenticateByName")
                XCTAssertNil(instance.request.value(forHTTPHeaderField: "X-Emby-Token"))
                instance.respond(body: Data("{\"AccessToken\":\"token-\(authCount)\",\"User\":{\"Id\":\"user\"}}".utf8))
            } else {
                let expected = instance.request.url!.host == "old.test" ? "token-1" : "token-2"
                XCTAssertEqual(instance.request.value(forHTTPHeaderField: "X-Emby-Token"), expected)
                instance.respond(body: Data("{\"Items\":[]}".utf8))
            }
        }
        let network = NetworkURLProtocol.session()
        defer { network.invalidateAndCancel() }
        _ = try await EmbyClient.list(source: source, parentID: "", password: "p", store: fixture.store, network: network)
        source.baseURL = "https://new.test/emby"
        source.username = "other"
        XCTAssertTrue(fixture.store.update(source, password: "new-password"))
        _ = try await EmbyClient.list(source: source, parentID: "", password: "new-password", store: fixture.store, network: network)
        XCTAssertEqual(authCount, 2)
        XCTAssertFalse(NetworkURLProtocol.recordedRequests.contains { $0.url?.path.contains("/emby/emby/") == true })
    }

    func testLateAuthenticationAfterDeleteCannotResurrectSecrets() async throws {
        let fixture = NetworkStoreFixture()
        let source = fixture.source()
        let started = expectation(description: "authentication started")
        var pending: NetworkURLProtocol?
        NetworkURLProtocol.install { instance in pending = instance; started.fulfill() }
        let network = NetworkURLProtocol.session()
        defer { network.invalidateAndCancel() }
        let task = Task { try await EmbyClient.session(source: source, password: "p", store: fixture.store, network: network) }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(fixture.store.remove(source))
        pending?.respond(body: Data("{\"AccessToken\":\"late-token\",\"User\":{\"Id\":\"user\"}}".utf8))
        do { _ = try await task.value; XCTFail("Late result accepted") } catch {}
        XCTAssertNil(try fixture.secrets.data(account: source.id.uuidString + ".embySession", service: MediaServerStore.keychainService))
    }

    func testConcurrentLateAuthenticationCannotReplaceAlreadyCommittedSession() async throws {
        let fixture = NetworkStoreFixture()
        let source = fixture.source()
        let started = expectation(description: "both authentications started")
        started.expectedFulfillmentCount = 2
        var pending: [NetworkURLProtocol] = []
        NetworkURLProtocol.install { instance in pending.append(instance); started.fulfill() }
        let network = NetworkURLProtocol.session()
        defer { network.invalidateAndCancel() }
        let first = Task { try await EmbyClient.session(source: source, password: "p", store: fixture.store, network: network) }
        let second = Task { try await EmbyClient.session(source: source, password: "p", store: fixture.store, network: network) }
        await fulfillment(of: [started], timeout: 1)
        pending[1].respond(body: Data("{\"AccessToken\":\"first-committed\",\"User\":{\"Id\":\"user\"}}".utf8))
        try await Task.sleep(nanoseconds: 10_000_000)
        pending[0].respond(body: Data("{\"AccessToken\":\"late\",\"User\":{\"Id\":\"user\"}}".utf8))
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult.token, "first-committed")
        XCTAssertEqual(secondResult.token, "first-committed")
        let cached = try await EmbyClient.session(source: source, password: "p", store: fixture.store, network: network)
        XCTAssertEqual(cached.token, "first-committed")
        XCTAssertEqual(NetworkURLProtocol.recordedRequests.count, 2)
    }

    func testAuthenticationCannotRedirectPasswordToOtherHost() async throws {
        let fixture = NetworkStoreFixture()
        let source = fixture.source()
        NetworkURLProtocol.install { $0.respond(status: 302, headers: ["Location": "https://external.test/collect"]) }
        let network = NetworkURLProtocol.session()
        defer { network.invalidateAndCancel() }
        do { _ = try await EmbyClient.session(source: source, password: "p", store: fixture.store, network: network); XCTFail("Redirect accepted") } catch {}
        XCTAssertEqual(NetworkURLProtocol.recordedRequests.count, 1)
    }
}
