import XCTest
import Libmpv
@testable import BrushLLMPlayer

final class PlaybackTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testStringEventCopiesPointerValue() {
        for value in ["", "Movie", "中文电影"] {
            value.withCString { string in
                var pointer: UnsafePointer<CChar>? = string
                withUnsafeMutablePointer(to: &pointer) { data in
                    let property = mpv_event_property(name: nil, format: MPV_FORMAT_STRING, data: data)
                    guard case .string(let parsed)? = MPVController.parsePropertyValue(property) else {
                        return XCTFail("missing string")
                    }
                    XCTAssertEqual(parsed, value)
                }
            }
        }
        var pointer: UnsafePointer<CChar>?
        withUnsafeMutablePointer(to: &pointer) { data in
            XCTAssertNil(MPVController.parsePropertyValue(mpv_event_property(name: nil, format: MPV_FORMAT_STRING, data: data)))
        }
    }

    func testPlaylistMovesUseInsertionOffsets() {
        XCTAssertEqual(PlaylistOrder.moving(4, from: [0], to: 2), [1, 0, 2, 3])
        XCTAssertEqual(PlaylistOrder.moving(4, from: [3], to: 0), [3, 0, 1, 2])
        XCTAssertEqual(PlaylistOrder.moving(4, from: [0], to: 4), [1, 2, 3, 0])
        XCTAssertEqual(PlaylistOrder.moving(4, from: [0, 2], to: 4), [1, 3, 0, 2])
        XCTAssertEqual(PlaylistOrder.moving(4, from: [1], to: 2), [0, 1, 2, 3])
    }

    func testColorsConvertRGBAtoMPVAlphaFirst() throws {
        XCTAssertEqual(try XCTUnwrap(SubtitleColor(hex: "#000000FF")).mpvValue, "#FF000000")
        XCTAssertEqual(try XCTUnwrap(SubtitleColor(hex: "#893CEDFF")).mpvValue, "#FF893CED")
        XCTAssertEqual(try XCTUnwrap(SubtitleColor(hex: "#FFE000FF")).mpvValue, "#FFFFE000")
        XCTAssertEqual(try XCTUnwrap(SubtitleColor(hex: "#893CED")).mpvValue, "#FF893CED")
        XCTAssertNil(SubtitleColor(hex: "#invalid"))
    }

    func testLogRedactionRemovesUserInfoQueriesAndFragments() {
        let redacted = URLPrivacy.redact("open https://alice:p%40ss@host/video.mp4?api_key=secret#token ftp://user:pass@nas/song.flac")
        XCTAssertEqual(redacted, "open https://host/video.mp4 ftp://nas/song.flac")
    }

    func testNewSecretsNeverEnterJSONAndCanBeReopened() throws {
        let secrets = FakePlaybackSecrets()
        let file = directory.appendingPathComponent("playback.json")
        let store = PlaybackStore(fileURL: file, secretStore: secrets)
        let reference = MediaReference.url(try XCTUnwrap(URL(string: "ftp://alice:password@nas/video.mp4")))
        store.recordPlay(reference: reference, title: "video", duration: 120)
        let protected = try XCTUnwrap(store.history.first?.reference)
        store.addBookmark(reference: protected, title: "video", time: 30)
        store.flush()
        let json = try String(contentsOf: file)
        XCTAssertFalse(json.contains("password"))
        XCTAssertFalse(json.contains("alice"))
        XCTAssertEqual(try store.originalReference(protected), reference)
        let reloaded = PlaybackStore(fileURL: file, secretStore: secrets)
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.bookmarks.count, 1)
    }

    func testLegacyMigrationProtectsURLAndPreservesPosition() throws {
        let file = directory.appendingPathComponent("playback.json")
        let path = "https://host/movie.mp4?api_key=old-secret"
        let history = HistoryEntry(path: path, title: path, duration: 100, position: 23,
                                   lastPlayedAt: Date(), playCount: 2)
        let bookmark = Bookmark(path: path, title: "movie", time: 12, note: "", createdAt: Date())
        let data = try JSONEncoder().encode(LegacyPayload(history: [history], bookmarks: [bookmark]))
        try data.write(to: file)
        let secrets = FakePlaybackSecrets()
        let store = PlaybackStore(fileURL: file, secretStore: secrets)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.history.first?.position, 23)
        XCTAssertEqual(store.bookmarks.first?.time, 12)
        XCTAssertFalse(try String(contentsOf: file).contains("old-secret"))
        XCTAssertEqual(try store.originalReference(try XCTUnwrap(store.history.first?.reference)).location, path)
        XCTAssertFalse(secrets.values.keys.contains { $0.contains("migration-backup") })
    }

    func testFailedMigrationAndCorruptJSONDoNotOverwriteSource() throws {
        let file = directory.appendingPathComponent("playback.json")
        for data in [Data("broken json".utf8), try JSONEncoder().encode(LegacyPayload(history: [
            HistoryEntry(path: "ftp://alice:password@host/video", title: "video", duration: 4,
                         position: 2, lastPlayedAt: Date(), playCount: 1)
        ], bookmarks: []))] {
            try data.write(to: file)
            let secrets = FakePlaybackSecrets()
            secrets.failWrites = true
            let store = PlaybackStore(fileURL: file, secretStore: secrets)
            XCTAssertNotNil(store.lastError)
            if String(data: data, encoding: .utf8)?.hasPrefix("{") == true {
                XCTAssertEqual(store.history.count, 1)
                XCTAssertEqual(store.history.first?.position, 2)
            }
            store.clearHistory()
            store.flush()
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testUnknownPayloadVersionIsPreserved() throws {
        let file = directory.appendingPathComponent("playback.json")
        let data = Data(#"{"version":99,"history":[],"bookmarks":[]}"#.utf8)
        try data.write(to: file)
        let store = PlaybackStore(fileURL: file, secretStore: FakePlaybackSecrets())
        XCTAssertNotNil(store.lastError)
        store.recordPlay(path: "/a", title: "a", duration: 10)
        store.flush()
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testHistoryRevisitMovesToFrontAndFiniteValuesPersist() throws {
        let file = directory.appendingPathComponent("playback.json")
        let store = PlaybackStore(fileURL: file, secretStore: FakePlaybackSecrets())
        store.recordPlay(path: "/a", title: "a", duration: 100)
        store.recordPlay(path: "/b", title: "b", duration: 100)
        store.recordPlay(path: "/a", title: "a", duration: .infinity)
        store.updatePosition(path: "/a", position: .nan)
        store.flush()
        XCTAssertEqual(store.history.map(\.path), ["/a", "/b"])
        XCTAssertEqual(store.history.first?.playCount, 2)
        XCTAssertEqual(store.history.first?.position, 0)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: file)))
    }

    func testDiscSelectionEscapesEDLAndUsesUniqueFile() throws {
        let video = directory.appendingPathComponent("VIDEO_TS")
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: false)
        for name in ["VTS_01_0.VOB", "VTS_01_2.VOB", "VTS_01_1.VOB"] {
            try Data(repeating: 1, count: 20).write(to: video.appendingPathComponent(name))
        }
        let first = try DiscImageResource.selectMedia(at: directory)
        let second = try DiscImageResource.selectMedia(at: directory)
        defer {
            if let url = first.edl { try? FileManager.default.removeItem(at: url) }
            if let url = second.edl { try? FileManager.default.removeItem(at: url) }
        }
        XCTAssertEqual(first.vobs.map { URL(fileURLWithPath: $0).lastPathComponent }, ["VTS_01_1.VOB", "VTS_01_2.VOB"])
        XCTAssertNotEqual(first.path, second.path)
        let text = try String(contentsOfFile: first.path)
        XCTAssertTrue(text.contains("%\(first.vobs[0].utf8.count)%\(first.vobs[0])"))
    }

    private struct LegacyPayload: Encodable {
        let history: [HistoryEntry]
        let bookmarks: [Bookmark]
    }
}

private final class FakePlaybackSecrets: SecretStore {
    var values: [String: Data] = [:]
    var failWrites = false
    func data(account: String, service: String) throws -> Data? { values[service + account] }
    func set(_ data: Data, account: String, service: String) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        values[service + account] = data
    }
    func delete(account: String, service: String) throws { values.removeValue(forKey: service + account) }
}
