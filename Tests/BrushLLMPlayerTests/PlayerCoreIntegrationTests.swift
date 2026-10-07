import XCTest
import Libmpv
@testable import BrushLLMPlayer

final class PlayerCoreIntegrationTests: XCTestCase {
    @MainActor
    func testLogicalPlaylistSwitchStopAndResumeWithActualMPV() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.wav")
        let second = directory.appendingPathComponent("second.wav")
        try wave().write(to: first)
        try wave().write(to: second)
        let store = PlaybackStore(fileURL: directory.appendingPathComponent("history.json"), secretStore: MemorySecrets())
        let player = PlayerCore(playbackStore: store, headless: true)
        player.mpv.setFlag("pause", true)
        defer { player.shutdown() }
        player.open([first, second])
        for _ in 0..<200 {
            if !player.isIdle, player.fileName == "first.wav", player.playlist.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(player.loadErrorMessage)
        XCTAssertFalse(player.isIdle)
        XCTAssertEqual(player.fileName, "first.wav")
        XCTAssertEqual(player.playlist.count, 2)
        let ids = player.playlist.map(\.id)
        player.seek(to: 0.25)
        for _ in 0..<100 {
            if player.position >= 0.2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        player.playPlaylistIndex(1)
        for _ in 0..<200 {
            if player.fileName == "second.wav", !player.isIdle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(player.fileName, "second.wav")
        XCTAssertEqual(player.playlist.map(\.id), ids)
        XCTAssertEqual(store.history.count, 2)
        XCTAssertGreaterThan(store.history.first { $0.path == first.path }?.position ?? 0, 0.15)
        player.stop()
        for _ in 0..<200 {
            if player.isIdle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(player.isIdle)
        player.togglePlay()
        for _ in 0..<200 {
            if !player.isIdle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(player.isIdle)
        XCTAssertNil(player.loadErrorMessage)
    }

    @MainActor
    func testBookmarkedOtherFileLoadsThenSeeksAndMissingFileReportsError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.wav")
        let second = directory.appendingPathComponent("second.wav")
        try wave().write(to: first)
        try wave().write(to: second)
        let store = PlaybackStore(fileURL: directory.appendingPathComponent("history.json"), secretStore: MemorySecrets())
        let player = PlayerCore(playbackStore: store, headless: true)
        player.mpv.setFlag("pause", true)
        defer { player.shutdown() }
        player.open(first)
        try await waitUntil { player.fileName == "first.wav" && !player.isIdle }
        let bookmark = Bookmark(path: second.path, media: .file(second.path), title: "second", time: 0.3,
                                note: "", createdAt: Date())
        player.openBookmark(bookmark)
        try await waitUntil { player.fileName == "second.wav" && player.position >= 0.25 && !player.isIdle }
        XCTAssertEqual(store.history.first?.path, second.path)
        XCTAssertGreaterThanOrEqual(player.position, 0.25)
        player.open(directory.appendingPathComponent("missing.wav"))
        try await waitUntil { player.loadErrorMessage != nil }
        XCTAssertNotNil(player.loadErrorMessage)
        player.open(first)
        try await waitUntil { player.fileName == "first.wav" && !player.isIdle }
        XCTAssertNil(player.loadErrorMessage)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Player did not reach expected state")
    }

    private func wave() -> Data {
        let samples = 8000
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        text("RIFF"); integer(UInt32(36 + samples * 2)); text("WAVEfmt "); integer(UInt32(16))
        integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(8000)); integer(UInt32(16000))
        integer(UInt16(2)); integer(UInt16(16)); text("data"); integer(UInt32(samples * 2))
        data.append(Data(repeating: 0, count: samples * 2))
        return data
    }
}

private final class MemorySecrets: SecretStore {
    private var items: [String: Data] = [:]
    func data(account: String, service: String) throws -> Data? { items[service + account] }
    func set(_ data: Data, account: String, service: String) throws { items[service + account] = data }
    func delete(account: String, service: String) throws { items.removeValue(forKey: service + account) }
}
