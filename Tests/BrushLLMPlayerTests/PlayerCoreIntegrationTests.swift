import XCTest
import Libmpv
@testable import BrushLLMPlayer

final class PlayerCoreIntegrationTests: XCTestCase {
    @MainActor
    func testLoadsMatchingSidecarFromOriginalVideoFolder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("字幕 sample.y4m")
        var frames = Data("YUV4MPEG2 W16 H16 F24:1 Ip A1:1 C420jpeg\n".utf8)
        for _ in 0..<48 {
            frames.append(Data("FRAME\n".utf8))
            frames.append(Data(repeating: 128, count: 16 * 16 * 3 / 2))
        }
        try frames.write(to: video)
        let matching = directory.appendingPathComponent("字幕 sample.eng.srt")
        let unrelated = directory.appendingPathComponent("another clip.srt")
        for subtitle in [matching, unrelated] {
            try "1\n00:00:00,000 --> 00:00:01,500\nSidecar\n".write(to: subtitle, atomically: true, encoding: .utf8)
        }

        let store = PlaybackStore(fileURL: directory.appendingPathComponent("history.json"), secretStore: MemorySecrets())
        let player = PlayerCore(playbackStore: store, headless: true)
        defer { player.shutdown() }
        player.mpv.setFlag("pause", true)
        player.mpv.setString("sub-auto", "fuzzy")
        player.open(video)
        try await waitUntil { player.canSeekTimeline && player.subtitleTracks.contains { $0.isSelected } }
        XCTAssertEqual(player.subtitleTracks.compactMap(\.externalFilename).map { URL(fileURLWithPath: $0).lastPathComponent },
                       [matching.lastPathComponent])
    }

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
            if player.canSeekTimeline, player.fileName == "first.wav", player.playlist.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(player.loadErrorMessage)
        XCTAssertFalse(player.isIdle)
        XCTAssertEqual(player.fileName, "first.wav")
        XCTAssertEqual(player.mediaTitle, "first.wav")
        XCTAssertEqual(player.playlist.count, 2)
        let ids = player.playlist.map(\.id)
        let firstLoad = player.loadGeneration
        XCTAssertTrue(player.canSeekTimeline)
        player.seekTimeline(to: 0.25, generation: firstLoad)
        for _ in 0..<100 {
            if player.position >= 0.2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        player.playPlaylistIndex(1)
        for _ in 0..<200 {
            if player.fileName == "second.wav", player.canSeekTimeline { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(player.fileName, "second.wav")
        XCTAssertEqual(player.playlist.map(\.id), ids)
        XCTAssertEqual(store.history.count, 2)
        XCTAssertGreaterThan(store.history.first { $0.path == first.path }?.position ?? 0, 0.15)
        let secondLoad = player.loadGeneration
        XCTAssertTrue(player.canSeekTimeline)
        XCTAssertNotEqual(firstLoad, secondLoad)
        player.seekTimeline(to: 0.8, generation: firstLoad)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThan(player.position, 0.2)
        player.seekTimeline(to: 0.6, generation: secondLoad)
        try await waitUntil { player.position >= 0.5 }
        player.stop()
        for _ in 0..<200 {
            if player.isIdle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(player.isIdle)
        player.togglePlay()
        for _ in 0..<200 {
            if player.canSeekTimeline { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(player.isIdle)
        XCTAssertNil(player.loadErrorMessage)
        XCTAssertTrue(player.canSeekTimeline)
        XCTAssertNotEqual(secondLoad, player.loadGeneration)
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
