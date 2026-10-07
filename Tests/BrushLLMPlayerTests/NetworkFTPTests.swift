import Foundation
import XCTest
@testable import BrushLLMPlayer

final class NetworkFTPTests: XCTestCase {
    private let source = MediaServerSource(kind: .ftp, name: "test", baseURL: "ftp://ftp.test", username: "alice")

    func testEmptyDataTransferAndSplitControlReplies() async throws {
        let control = NetworkFakeFTPConnection(["220-Wel", "come\r\n220 Ready\r\n331 Password\r\n230 OK\r\n200 Binary\r\n227 Passive (0,0,0,0,12,34)\r\n150 Opening\r\n226 Complete\r\n"])
        let data = NetworkFakeFTPConnection([""], done: true)
        var connections = [control, data]
        let items = try await FTPClient.list(source: source, path: "/", password: "p", timeout: 1) { host, port in
            XCTAssertEqual(host, "ftp.test")
            XCTAssertEqual(port, connections.count == 2 ? 21 : 3106)
            return connections.removeFirst()
        }
        XCTAssertTrue(items.isEmpty)
        XCTAssertGreaterThan(control.cancelCount, 0)
        XCTAssertGreaterThan(data.cancelCount, 0)
    }

    func testSilentConnectGreetingAndDataHaveWholeOperationDeadline() async throws {
        for stage in ["connect", "greeting", "data"] {
            let control = NetworkFakeFTPConnection(stage == "data" ? ["220 Ready\r\n331 Password\r\n230 OK\r\n200 Binary\r\n227 Passive (127,0,0,1,12,34)\r\n150 Opening\r\n"] : [])
            control.startSilently = stage == "connect"
            control.silenceAfterChunks = true
            let data = NetworkFakeFTPConnection()
            data.silenceAfterChunks = true
            var connections = [control, data]
            let start = Date()
            do {
                _ = try await FTPClient.list(source: source, path: "/", password: "p", timeout: 0.05) { _, _ in connections.removeFirst() }
                XCTFail("Silent \(stage) succeeded")
            } catch {
                XCTAssertEqual(error.localizedDescription, FTPClient.FTPError.timeout.localizedDescription)
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
            XCTAssertGreaterThan(control.cancelCount, 0)
            if stage == "data" { XCTAssertGreaterThan(data.cancelCount, 0) }
        }
    }

    func testCancellationDuringDataReadClosesBothConnections() async throws {
        let control = NetworkFakeFTPConnection(["220 Ready\r\n331 Password\r\n230 OK\r\n200 Binary\r\n227 Passive (127,0,0,1,12,34)\r\n150 Opening\r\n"])
        control.silenceAfterChunks = true
        let data = NetworkFakeFTPConnection()
        data.silenceAfterChunks = true
        let task = Task {
            var connections = [control, data]
            return try await FTPClient.list(source: source, path: "/", password: "p", timeout: 10) { _, _ in connections.removeFirst() }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled listing succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertGreaterThan(control.cancelCount, 0)
        XCTAssertGreaterThan(data.cancelCount, 0)
    }

    func testEOFWithHalfReplyFailsAndMLSDRejectionUsesFreshDataConnection() async throws {
        let eof = NetworkFakeFTPConnection(["220 half greeting"], done: true)
        do { _ = try await FTPClient.list(source: source, path: "/", password: "p", timeout: 1) { _, _ in eof }; XCTFail("Half greeting accepted") } catch {}
        let control = NetworkFakeFTPConnection(["220 Ready\r\n331 Password\r\n230 OK\r\n200 Binary\r\n227 Passive (127,0,0,1,12,34)\r\n500 MLSD unknown\r\n227 Passive (127,0,0,1,12,35)\r\n150 Opening\r\n226 Complete\r\n"])
        let firstData = NetworkFakeFTPConnection()
        let secondData = NetworkFakeFTPConnection(["-rw-r--r-- 1 owner group 42 Oct 7 2026 file.mp4\r\n"], done: true)
        var connections = [control, firstData, secondData]
        let items = try await FTPClient.list(source: source, path: "/", password: "p", timeout: 1) { _, _ in connections.removeFirst() }
        XCTAssertEqual(items.map(\.id), ["/file.mp4"])
        XCTAssertGreaterThan(firstData.cancelCount, 0)
        XCTAssertNotNil(items.first?.modifiedAt)
    }

    func testFTPCommandInjectionIsRejected() async throws {
        let control = NetworkFakeFTPConnection(["220 Ready\r\n"])
        var source = self.source
        source.username = "alice\r\nDELE secret"
        do { _ = try await FTPClient.list(source: source, path: "/", password: "p", timeout: 1) { _, _ in control }; XCTFail("Injection accepted") } catch {}
        XCTAssertTrue(control.commands.isEmpty)
    }
}
