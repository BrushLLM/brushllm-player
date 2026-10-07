import XCTest
import Foundation
@testable import BrushLLMPlayer

/// Every runner is a local fake. These tests never invoke hdiutil, mount a
/// volume, or alter the live application's global shutdown state.
final class DiscLifecycleTests: XCTestCase {
    private func waitFor(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("fixture timed out"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testParentCancellationReachesAttachAndOnlyOwnedDeviceIsCleaned() async throws {
        let lifecycle = DiscImageResource.Lifecycle()
        let fake = DiscRunnerFixture(blockAttach: true)
        let task = Task {
            try await DiscImageResource.mount("synthetic.iso", lifecycle: lifecycle,
                runner: { try fake.run($0, $1) }, selector: { _ in ("synthetic-stream", [], nil) })
        }
        try await waitFor { fake.started }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled attach returned resource") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cleaned = await DiscImageResource.waitForCleanup(lifecycle: lifecycle, timeout: 1)
        XCTAssertTrue(cleaned)
        XCTAssertTrue(fake.sawCancellation)
        XCTAssertEqual(fake.detached, ["/dev/fake-owned"])
        XCTAssertFalse(fake.directories.contains { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testShutdownDeadlineIncludesInFlightAttachAndItsLateOwnedDetach() async throws {
        let lifecycle = DiscImageResource.Lifecycle()
        let fake = DiscRunnerFixture(blockAttach: true, detachDelay: 0.05)
        let task = Task {
            try await DiscImageResource.mount("synthetic.iso", lifecycle: lifecycle,
                runner: { try fake.run($0, $1) }, selector: { _ in ("synthetic-stream", [], nil) })
        }
        try await waitFor { fake.started }
        let start = ProcessInfo.processInfo.systemUptime
        let cleaned = await DiscImageResource.shutdown(lifecycle: lifecycle, timeout: 0.5)
        XCTAssertTrue(cleaned)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.6)
        XCTAssertTrue(fake.sawCancellation)
        XCTAssertEqual(fake.detached, ["/dev/fake-owned"])
        do { _ = try await task.value; XCTFail("shutdown attach returned resource") } catch {}
    }

    func testUnknownTimedOutAttachNeverGuessesOrDetachesAnotherDevice() async throws {
        let lifecycle = DiscImageResource.Lifecycle()
        let fake = DiscRunnerFixture(unknownOutput: true)
        do {
            _ = try await DiscImageResource.mount("synthetic.iso", lifecycle: lifecycle,
                runner: { try fake.run($0, $1) }, selector: { _ in ("synthetic-stream", [], nil) })
            XCTFail("invalid attach succeeded")
        } catch {}
        let cleaned = await DiscImageResource.waitForCleanup(lifecycle: lifecycle, timeout: 0.2)
        XCTAssertTrue(cleaned)
        XCTAssertEqual(fake.detached, [])
        XCTAssertFalse(fake.directories.contains { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testConsumerLeaseBlocksDetachAndReleaseIsIdempotent() async throws {
        let lifecycle = DiscImageResource.Lifecycle()
        let fake = DiscRunnerFixture()
        let resource = try await DiscImageResource.mount("synthetic.iso", lifecycle: lifecycle,
            runner: { try fake.run($0, $1) }, selector: { _ in ("synthetic-stream", [], nil) })
        let lease = try XCTUnwrap(resource.retainConsumer())
        resource.release()
        resource.release()
        let prematurelyCleaned = await DiscImageResource.waitForCleanup(lifecycle: lifecycle, timeout: 0.03)
        XCTAssertFalse(prematurelyCleaned)
        XCTAssertEqual(fake.detached, [])
        XCTAssertNil(resource.retainConsumer())
        lease.release()
        lease.release()
        let cleaned = await DiscImageResource.waitForCleanup(lifecycle: lifecycle, timeout: 1)
        XCTAssertTrue(cleaned)
        XCTAssertEqual(fake.detached, ["/dev/fake-owned"])
    }

    func testBusyDetachKeepsResourceAndCanRetryWithoutPrematureEDLRemoval() async throws {
        let lifecycle = DiscImageResource.Lifecycle()
        let fake = DiscRunnerFixture(busy: true)
        let edl = FileManager.default.temporaryDirectory.appendingPathComponent("disc-test-\(UUID().uuidString).edl")
        try Data("synthetic edl".utf8).write(to: edl)
        defer { try? FileManager.default.removeItem(at: edl) }
        let resource = try await DiscImageResource.mount("synthetic.iso", lifecycle: lifecycle,
            runner: { try fake.run($0, $1) }, selector: { _ in ("synthetic-stream", [], edl) })
        resource.release()
        let failed = await DiscImageResource.waitForCleanup(lifecycle: lifecycle, timeout: 0.05)
        XCTAssertFalse(failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: edl.path))
        XCTAssertTrue(fake.directories.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        fake.setBusy(false)
        resource.release()
        let cleaned = await DiscImageResource.waitForCleanup(lifecycle: lifecycle, timeout: 1)
        XCTAssertTrue(cleaned)
        XCTAssertGreaterThanOrEqual(fake.detached.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: edl.path))
    }

    func testSelectionFailureAfterOwnershipStillDetachesItsDevice() async throws {
        let lifecycle = DiscImageResource.Lifecycle()
        let fake = DiscRunnerFixture()
        do {
            _ = try await DiscImageResource.mount("synthetic.iso", lifecycle: lifecycle,
                runner: { try fake.run($0, $1) }, selector: { _ in throw CocoaError(.fileReadCorruptFile) })
            XCTFail("selection failure succeeded")
        } catch {}
        let cleaned = await DiscImageResource.waitForCleanup(lifecycle: lifecycle, timeout: 1)
        XCTAssertTrue(cleaned)
        XCTAssertEqual(fake.detached, ["/dev/fake-owned"])
    }
}

private final class DiscRunnerFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let blockAttach: Bool
    private let unknownOutput: Bool
    private let detachDelay: TimeInterval
    private var busy: Bool
    private var didStart = false
    private var didCancel = false
    private var detachCalls: [String] = []
    private var mountDirectories: [URL] = []
    init(blockAttach: Bool = false, unknownOutput: Bool = false, detachDelay: TimeInterval = 0, busy: Bool = false) {
        self.blockAttach = blockAttach; self.unknownOutput = unknownOutput
        self.detachDelay = detachDelay; self.busy = busy
    }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
    var sawCancellation: Bool { lock.lock(); defer { lock.unlock() }; return didCancel }
    var detached: [String] { lock.lock(); defer { lock.unlock() }; return detachCalls }
    var directories: [URL] { lock.lock(); defer { lock.unlock() }; return mountDirectories }
    func setBusy(_ value: Bool) { lock.lock(); busy = value; lock.unlock() }
    func run(_ arguments: [String], _ control: DiscImageResource.CommandControl) throws -> DiscImageResource.CommandResult {
        if arguments.first == "attach" {
            let directory = URL(fileURLWithPath: try XCTUnwrap(arguments.last))
            lock.lock(); didStart = true; mountDirectories.append(directory); lock.unlock()
            if blockAttach {
                while !control.state.cancelled && ProcessInfo.processInfo.systemUptime < control.state.deadline { usleep(2_000) }
            }
            lock.lock(); didCancel = control.state.cancelled; lock.unlock()
            let path = unknownOutput ? directory.appendingPathComponent("not-our-mount").path : directory.path
            let data = try PropertyListSerialization.data(fromPropertyList: ["system-entities": [
                ["dev-entry": "/dev/unrelated", "mount-point": "/an/unrelated/mount"],
                ["dev-entry": "/dev/fake-owned", "mount-point": path],
            ]], format: .xml, options: 0)
            return DiscImageResource.CommandResult(output: data, status: unknownOutput ? -1 : 0,
                cancelled: control.state.cancelled, timedOut: unknownOutput)
        }
        XCTAssertEqual(arguments.first, "detach")
        lock.lock(); detachCalls.append(arguments[1]); let isBusy = busy; lock.unlock()
        if detachDelay > 0 { usleep(useconds_t(detachDelay * 1_000_000)) }
        return DiscImageResource.CommandResult(status: isBusy ? 1 : 0)
    }
}
