import Foundation
import XCTest
@testable import BrushLLMPlayer

final class NetworkSecretStoreTests: XCTestCase {
    func testFailedAddAndUpdatePreservePasswordAndMetadata() throws {
        let fixture = NetworkStoreFixture()
        fixture.secrets.rejectWrites = true
        XCTAssertNil(fixture.store.add(kind: .webdav, name: "Test", baseURL: "https://dav.test", username: "alice", password: "initial"))
        XCTAssertTrue(fixture.store.sources.isEmpty)
        XCTAssertNotNil(fixture.store.lastError)
        fixture.secrets.rejectWrites = false
        let source = fixture.source(kind: .webdav)
        let originalData = fixture.defaults.data(forKey: "mediaServers")
        var edited = source
        edited.username = "bob"
        fixture.secrets.rejectWrites = true
        XCTAssertFalse(fixture.store.update(edited, password: "replacement"))
        XCTAssertEqual(fixture.store.sources, [source])
        XCTAssertEqual(fixture.defaults.data(forKey: "mediaServers"), originalData)
        XCTAssertEqual(try fixture.store.readPassword(for: source), "synthetic-password")
        XCTAssertNotNil(fixture.store.lastError)
        XCTAssertThrowsError(try fixture.store.configuration(for: source))
        let reopened = MediaServerStore(defaults: fixture.defaults, secretStore: fixture.secrets)
        XCTAssertThrowsError(try reopened.configuration(for: source))
        fixture.secrets.rejectWrites = false
        XCTAssertTrue(fixture.store.update(source, password: "synthetic-password"))
        XCTAssertNoThrow(try fixture.store.configuration(for: source))
    }

    func testConfigurationVersionBlocksLateCredentialsAndRemoveDeletesAuxiliaries() throws {
        let fixture = NetworkStoreFixture()
        let source = fixture.source()
        let old = try fixture.store.configuration(for: source)
        try fixture.store.setSecret("old-token", account: "embyToken", for: source, configuration: old)
        try fixture.store.setSecret("extra", account: "custom-secret", for: source, configuration: old)
        var edited = source
        edited.baseURL = "https://other.test"
        XCTAssertTrue(fixture.store.update(edited, password: nil))
        XCTAssertFalse(fixture.store.isCurrent(old))
        XCTAssertThrowsError(try fixture.store.setSecret("late-token", account: "embySession", for: source, configuration: old))
        XCTAssertNil(try fixture.store.readSecret(account: "embyToken", for: edited))
        try fixture.store.setSecret("new-token", account: "embyToken", for: edited)
        try fixture.store.setSecret("aux", account: "custom-secret", for: edited)
        XCTAssertTrue(fixture.store.remove(edited))
        for account in [source.id.uuidString, source.id.uuidString + ".embyToken", source.id.uuidString + ".custom-secret"] {
            XCTAssertNil(try fixture.secrets.data(account: account, service: MediaServerStore.keychainService))
        }
        XCTAssertThrowsError(try fixture.store.readPassword(for: edited))
        XCTAssertThrowsError(try fixture.store.setSecret("revived", account: "embySession", for: edited))
    }

    func testRemoveFailureIsReportedAndMetadataRetained() {
        let fixture = NetworkStoreFixture()
        let source = fixture.source()
        fixture.secrets.rejectDeletes = true
        XCTAssertFalse(fixture.store.remove(source))
        XCTAssertEqual(fixture.store.sources, [source])
        XCTAssertNotNil(fixture.store.lastError)
    }

    func testReadFailureIsNotSilentlyAnonymous() {
        let fixture = NetworkStoreFixture()
        let source = fixture.source()
        fixture.secrets.rejectedRead = true
        XCTAssertThrowsError(try fixture.store.readPassword(for: source))
        XCTAssertNil(fixture.store.password(for: source))
        XCTAssertNotNil(fixture.store.lastError)
    }

    func testLegacyServiceAndUUIDArePreservedAndDamagedMetadataIsNotOverwritten() throws {
        let fixture = NetworkStoreFixture()
        let id = UUID()
        fixture.defaults.set(Data("[{\"id\":\"\(id.uuidString)\",\"name\":\"Legacy\",\"baseURL\":\"https://dav.test\",\"username\":\"alice\"}]".utf8), forKey: "webdavSources")
        try fixture.secrets.set(Data("old-password".utf8), account: id.uuidString, service: "dev.brushllm.player.webdav")
        let migrated = MediaServerStore(defaults: fixture.defaults, secretStore: fixture.secrets)
        let source = try XCTUnwrap(migrated.sources.first)
        XCTAssertEqual(source.id, id)
        XCTAssertEqual(source.kind, .webdav)
        XCTAssertEqual(try migrated.readPassword(for: source), "old-password")
        XCTAssertNil(fixture.defaults.data(forKey: "webdavSources"))
        let damaged = Data("not valid json".utf8)
        fixture.defaults.set(damaged, forKey: "mediaServers")
        let store = MediaServerStore(defaults: fixture.defaults, secretStore: fixture.secrets)
        XCTAssertNotNil(store.lastError)
        XCTAssertNil(store.add(kind: .ftp, name: "new", baseURL: "ftp://ftp.test", username: "alice", password: "p"))
        XCTAssertEqual(fixture.defaults.data(forKey: "mediaServers"), damaged)
    }
}
