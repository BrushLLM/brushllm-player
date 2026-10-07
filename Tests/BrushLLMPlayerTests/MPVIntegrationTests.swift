import XCTest
import Libmpv
@testable import BrushLLMPlayer

final class MPVIntegrationTests: XCTestCase {
    func testLoadHookRewritesStreamWithoutReplacingPlaylistEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("音频, sample.wav")
        try wave().write(to: audio)
        let edl = directory.appendingPathComponent("disc.edl")
        try "# mpv EDL v0\n%\(audio.path.utf8.count)%\(audio.path)\n".write(to: edl, atomically: true, encoding: .utf8)
        let handle = try XCTUnwrap(mpv_create())
        defer { mpv_terminate_destroy(handle) }
        for (name, value) in [("config", "no"), ("load-scripts", "no"), ("terminal", "no"),
                              ("vo", "null"), ("ao", "null"), ("pause", "yes"), ("keep-open", "yes"),
                              ("save-position-on-quit", "no")] {
            XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, name, value), 0)
        }
        XCTAssertGreaterThanOrEqual(mpv_initialize(handle), 0)
        XCTAssertGreaterThanOrEqual(mpv_hook_add(handle, 0, "on_load", 0), 0)
        XCTAssertGreaterThanOrEqual(mpv_hook_add(handle, 0, "on_unload", 0), 0)
        try command(handle, ["loadfile", "brushplayer://media/first", "replace"])
        try command(handle, ["loadfile", "brushplayer://media/second", "append"])
        let firstIDs = try ids(handle)
        var loaded = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !loaded {
            guard let event = mpv_wait_event(handle, 0.1) else { continue }
            if event.pointee.event_id == MPV_EVENT_HOOK {
                let hook = event.pointee.data.assumingMemoryBound(to: mpv_event_hook.self).pointee
                XCTAssertGreaterThanOrEqual(mpv_set_property_string(handle, "stream-open-filename", edl.path), 0)
                XCTAssertGreaterThanOrEqual(mpv_hook_continue(handle, hook.id), 0)
            } else if event.pointee.event_id == MPV_EVENT_FILE_LOADED { loaded = true }
            else if event.pointee.event_id == MPV_EVENT_END_FILE {
                let end = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR { XCTFail("EDL hook load error \(end.error)"); break }
            }
        }
        XCTAssertTrue(loaded)
        XCTAssertEqual(try ids(handle), firstIDs)
        XCTAssertEqual(firstIDs.count, 2)
        try command(handle, ["playlist-play-index", "1"])
        var secondHook = false
        var unloadSeen = false
        let secondDeadline = Date().addingTimeInterval(5)
        while Date() < secondDeadline, !secondHook {
            guard let event = mpv_wait_event(handle, 0.1) else { continue }
            if event.pointee.event_id == MPV_EVENT_HOOK {
                let hook = event.pointee.data.assumingMemoryBound(to: mpv_event_hook.self).pointee
                let name = String(cString: hook.name)
                if name == "on_unload" {
                    unloadSeen = true
                    var position: Double = 0
                    XCTAssertGreaterThanOrEqual(mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &position), 0)
                    XCTAssertTrue(position.isFinite)
                } else {
                    secondHook = true
                    XCTAssertGreaterThanOrEqual(mpv_set_property_string(handle, "stream-open-filename", audio.path), 0)
                }
                XCTAssertGreaterThanOrEqual(mpv_hook_continue(handle, hook.id), 0)
            }
        }
        XCTAssertTrue(secondHook)
        XCTAssertTrue(unloadSeen)
        XCTAssertEqual(try ids(handle), firstIDs)
        try command(handle, ["stop", "keep-playlist"])
        let stopDeadline = Date().addingTimeInterval(5)
        var ended = false
        while Date() < stopDeadline, !ended {
            guard let event = mpv_wait_event(handle, 0.1) else { continue }
            if event.pointee.event_id == MPV_EVENT_HOOK {
                let hook = event.pointee.data.assumingMemoryBound(to: mpv_event_hook.self).pointee
                mpv_hook_continue(handle, hook.id)
            } else if event.pointee.event_id == MPV_EVENT_END_FILE { ended = true }
        }
        XCTAssertTrue(ended)
    }

    private func command(_ handle: OpaquePointer, _ args: [String]) throws {
        var pointers: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for case let pointer? in pointers { free(UnsafeMutablePointer(mutating: pointer)) } }
        XCTAssertGreaterThanOrEqual(mpv_command(handle, &pointers), 0)
    }

    private func ids(_ handle: OpaquePointer) throws -> [Int] {
        var node = mpv_node()
        XCTAssertGreaterThanOrEqual(mpv_get_property(handle, "playlist", MPV_FORMAT_NODE, &node), 0)
        defer { mpv_free_node_contents(&node) }
        return try XCTUnwrap(MPVNodeParser.parse(&node) as? [[String: Any]]).compactMap { $0["id"] as? Int }
    }

    private func wave() -> Data {
        let samples = 8000
        var data = Data()
        func bytes(_ text: String) { data.append(contentsOf: text.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        bytes("RIFF"); integer(UInt32(36 + samples * 2)); bytes("WAVEfmt "); integer(UInt32(16))
        integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(8000)); integer(UInt32(16000))
        integer(UInt16(2)); integer(UInt16(16)); bytes("data"); integer(UInt32(samples * 2))
        data.append(Data(repeating: 0, count: samples * 2))
        return data
    }
}
