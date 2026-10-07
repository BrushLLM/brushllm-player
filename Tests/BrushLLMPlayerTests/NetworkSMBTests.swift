import Foundation
import XCTest
@testable import BrushLLMPlayer

private final class NetworkFakeSMB {
    private let lock = NSLock()
    private var state: SMBMountSnapshot?
    private var identity: SMBDirectoryIdentity? = SMBDirectoryIdentity(device: 1, inode: 10)
    private var commands: [String] = []
    private var removals = 0
    var preexisting = false
    var busy = false
    var mountFails = false
    var mountTimeout = false
    var launchFails = false
    var unmountLaunchFails = false
    var onUnmount: (() -> Void)?
    let uncovered = SMBMountSnapshot(mountPoint: "/", fileSystem: "apfs", source: "/dev/disk-test", identifier: "root")
    enum Failure: Error { case denied }

    var dependencies: SMBMountDependencies {
        SMBMountDependencies(snapshot: { [self] _ in lock.lock(); defer { lock.unlock() }; return state ?? uncovered },
        createDirectory: { [self] _ in if preexisting { throw Failure.denied }; return SMBDirectoryIdentity(device: 1, inode: 10) },
        directoryIdentity: { [self] _ in lock.lock(); defer { lock.unlock() }; return identity },
        removeEmptyDirectory: { [self] _ in
            lock.lock(); defer { lock.unlock() }
            XCTAssertNil(state, "Must never remove a mount point")
            removals += 1
        }, command: { [self] executable, arguments, _ in
            lock.lock(); commands.append(executable); lock.unlock()
            if executable.hasSuffix("mount_smbfs") {
                if launchFails { throw Failure.denied }
                if !mountFails {
                    let url = URLComponents(string: arguments[1])!
                    let user = url.percentEncodedUser ?? "guest"
                    let snapshot = SMBMountSnapshot(mountPoint: arguments[2], fileSystem: "smbfs",
                                                    source: "//\(user)@\(url.host!)\(url.percentEncodedPath)", identifier: UUID().uuidString)
                    lock.lock(); state = snapshot; lock.unlock()
                }
                return SMBCommandResult(status: mountFails ? 1 : 0, timedOut: mountTimeout)
            }
            if unmountLaunchFails { throw Failure.denied }
            onUnmount?()
            lock.lock(); defer { lock.unlock() }
            if !busy { state = nil }
            return SMBCommandResult(status: busy ? 1 : 0, timedOut: false)
        })
    }
    var commandCount: Int { lock.lock(); defer { lock.unlock() }; return commands.count }
    var removalCount: Int { lock.lock(); defer { lock.unlock() }; return removals }
    func replaceMount(_ snapshot: SMBMountSnapshot) { lock.lock(); state = snapshot; lock.unlock() }
    func replaceDirectory() { lock.lock(); identity = SMBDirectoryIdentity(device: 1, inode: 99); lock.unlock() }
}

final class NetworkSMBTests: XCTestCase {
    private let source = MediaServerSource(kind: .smb, name: "test", baseURL: "smb://nas.test/Media", username: "alice")

    func testCredentialsAreEncodedExactlyOnce() throws {
        for password in ["p@ss", "100%", "a:b", "space here", "中文密码"] {
            let url = try SMBMountManager.shareURL(source: source, password: password)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.password, password)
            XCTAssertFalse(url.absoluteString.contains("p%2540ss"))
        }
    }

    func testOrdinaryDirectoryIsNotMountAndBusyReleaseRetainsRegistry() throws {
        let fake = NetworkFakeSMB()
        let manager = SMBMountManager(dependencies: fake.dependencies, rootPath: "/fake/mounts")
        let path = try manager.mount(source: source, password: "p")
        XCTAssertTrue(path.hasPrefix("/fake/mounts/"))
        XCTAssertEqual(fake.commandCount, 1, "Ordinary apfs directory still requires a mount command")
        fake.busy = true
        manager.releaseSession(source: source)
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.removalCount, 0)
        XCTAssertNotNil(manager.lastError(for: source))
        XCTAssertEqual(try manager.mount(source: source, password: "p"), path)
        XCTAssertEqual(fake.commandCount, 2, "Busy mount was retained, not remounted")
        fake.busy = false
        manager.releaseSession(source: source)
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.removalCount, 1)
        manager.releaseSession(source: source)
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.removalCount, 1, "Repeated release must be idempotent")
    }

    func testMountFailureLaunchFailureTimeoutAndShutdownNeverRemoveShare() throws {
        for failure in ["exit", "launch", "timeout"] {
            let fake = NetworkFakeSMB()
            fake.mountFails = failure == "exit"
            fake.launchFails = failure == "launch"
            fake.mountTimeout = failure == "timeout"
            let manager = SMBMountManager(dependencies: fake.dependencies, rootPath: "/fake/mounts")
            XCTAssertThrowsError(try manager.mount(source: source, password: "p"))
            if failure == "timeout" {
                XCTAssertEqual(fake.removalCount, 0, "A timed-out child may have mounted the share")
                fake.busy = true
                manager.releaseAllSessions()
                manager.waitForPendingOperations(source: source)
                XCTAssertEqual(fake.removalCount, 0)
            } else { XCTAssertEqual(fake.removalCount, 1, "Only our still-uncovered empty directory may be removed") }
        }
        let fake = NetworkFakeSMB()
        let manager = SMBMountManager(dependencies: fake.dependencies, rootPath: "/fake/mounts")
        _ = try manager.mount(source: source, password: "p")
        fake.unmountLaunchFails = true
        manager.releaseAllSessions()
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.removalCount, 0)
    }

    func testPreexistingWrongAndReplacedMountsAreNeverClaimedOrUnmounted() throws {
        let preexisting = NetworkFakeSMB()
        preexisting.preexisting = true
        let first = SMBMountManager(dependencies: preexisting.dependencies, rootPath: "/fake/mounts")
        XCTAssertThrowsError(try first.mount(source: source, password: "p"))
        XCTAssertEqual(preexisting.commandCount, 0)
        XCTAssertEqual(preexisting.removalCount, 0)

        for replacement in ["wrong-fs", "wrong-source", "other-instance"] {
            let fake = NetworkFakeSMB()
            let manager = SMBMountManager(dependencies: fake.dependencies, rootPath: "/fake/mounts")
            let path = try manager.mount(source: source, password: "p")
            fake.replaceMount(SMBMountSnapshot(mountPoint: path, fileSystem: replacement == "wrong-fs" ? "apfs" : "smbfs",
                                              source: replacement == "wrong-source" ? "//alice@other.test/Media" : "//alice@nas.test/Media",
                                              identifier: "replacement"))
            manager.releaseSession(source: source)
            manager.waitForPendingOperations(source: source)
            XCTAssertEqual(fake.commandCount, 1)
            XCTAssertEqual(fake.removalCount, 0)
            XCTAssertThrowsError(try manager.mount(source: source, password: "p"))
        }
    }

    func testPlaybackLeasePreventsSessionShutdownUntilReleased() throws {
        let fake = NetworkFakeSMB()
        let manager = SMBMountManager(dependencies: fake.dependencies, rootPath: "/fake/mounts")
        _ = try manager.mount(source: source, password: "p")
        let lease = manager.retain(source: source)
        manager.releaseAllSessions()
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.commandCount, 1)
        manager.release(lease)
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.commandCount, 2)
        XCTAssertEqual(fake.removalCount, 1)
        manager.release(lease)
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.commandCount, 2)
    }

    func testReconnectGenerationCannotBeCleanedByOldUnmount() throws {
        let fake = NetworkFakeSMB()
        let manager = SMBMountManager(dependencies: fake.dependencies, rootPath: "/fake/mounts")
        let path = try manager.mount(source: source, password: "p")
        var lease: SMBMountLease?
        fake.onUnmount = { lease = manager.retain(source: self.source) }
        manager.releaseSession(source: source)
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.removalCount, 0, "An old generation cannot rmdir a new reservation")
        fake.onUnmount = nil
        XCTAssertEqual(try manager.mount(source: source, password: "p"), path)
        XCTAssertEqual(fake.commandCount, 3)
        manager.release(try XCTUnwrap(lease))
        manager.releaseSession(source: source)
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.removalCount, 1)
    }

    func testTimedOutUncoveredMountCannotReconnectOrCleanLater() throws {
        let fake = NetworkFakeSMB()
        fake.mountTimeout = true
        fake.mountFails = true
        let manager = SMBMountManager(dependencies: fake.dependencies, rootPath: "/fake/mounts")
        XCTAssertThrowsError(try manager.mount(source: source, password: "p"))
        XCTAssertEqual(fake.removalCount, 0)
        manager.releaseAllSessions()
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.removalCount, 0)
        XCTAssertThrowsError(try manager.mount(source: source, password: "p"))
        XCTAssertEqual(fake.commandCount, 1)
    }

    func testShutdownReturnsBoundedlyWhenBusyAndSucceedsOnSafeRelease() async throws {
        let fake = NetworkFakeSMB()
        let manager = SMBMountManager(dependencies: fake.dependencies, rootPath: "/fake/mounts")
        _ = try manager.mount(source: source, password: "p")
        fake.busy = true
        let busy = await manager.shutdown(timeout: 0.1)
        XCTAssertFalse(busy)
        XCTAssertEqual(fake.removalCount, 0)
        fake.busy = false
        let clean = await manager.shutdown(timeout: 0.1)
        XCTAssertTrue(clean)
        XCTAssertEqual(fake.removalCount, 1)
    }

    func testDirectoryReplacementAfterUnmountPreventsRmdir() throws {
        let fake = NetworkFakeSMB()
        let manager = SMBMountManager(dependencies: fake.dependencies, rootPath: "/fake/mounts")
        _ = try manager.mount(source: source, password: "p")
        fake.onUnmount = { fake.replaceDirectory() }
        manager.releaseSession(source: source)
        manager.waitForPendingOperations(source: source)
        XCTAssertEqual(fake.removalCount, 0)
        XCTAssertNotNil(manager.lastError(for: source))
    }
}
