import Foundation
import Darwin

struct SMBMountSnapshot: Equatable {
    let mountPoint: String
    let fileSystem: String
    let source: String
    let identifier: String
}

struct SMBDirectoryIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

struct SMBCommandResult {
    let status: Int32
    let timedOut: Bool
}

/// No filesystem/process side effects are hardwired into the state machine.
/// Tests must inject all of these operations, never use the live singleton.
struct SMBMountDependencies {
    var snapshot: (String) throws -> SMBMountSnapshot
    var createDirectory: (String) throws -> SMBDirectoryIdentity
    var directoryIdentity: (String) throws -> SMBDirectoryIdentity?
    var removeEmptyDirectory: (String) throws -> Void
    var command: (String, [String], TimeInterval) throws -> SMBCommandResult

    static var live: SMBMountDependencies {
        SMBMountDependencies(snapshot: { path in
            var info = statfs()
            guard statfs(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            func string<T>(_ field: T) -> String {
                var value = field
                return withUnsafePointer(to: &value) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
                }
            }
            return SMBMountSnapshot(mountPoint: string(info.f_mntonname), fileSystem: string(info.f_fstypename),
                                    source: string(info.f_mntfromname), identifier: "\(info.f_fsid.val.0):\(info.f_fsid.val.1)")
        }, createDirectory: { path in
            let parent = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            // Exclusive mkdir: an existing directory/mount belongs to someone
            // else, even if it is empty or its name resembles ours.
            guard Darwin.mkdir(path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard let identity = try liveDirectoryIdentity(path) else { throw SMBClient.SMBError.ownership }
            return identity
        }, directoryIdentity: liveDirectoryIdentity, removeEmptyDirectory: { path in
            // This is the only removal primitive in the entire SMB client.
            // It cannot traverse a mounted share or nonempty directory.
            guard Darwin.rmdir(path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }, command: SMBProcessRunner.run)
    }

    private static func liveDirectoryIdentity(_ path: String) throws -> SMBDirectoryIdentity? {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return SMBDirectoryIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

/// Bounded wait; both pipes drain concurrently before the child starts.
/// Failed launch never reaches a wait or reads a pipe to EOF.
private enum SMBProcessRunner {
    static func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> SMBCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Diagnostic contents can contain credentials, so drain and discard.
        stdout.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        try process.run()
        let timedOut = exited.wait(timeout: .now() + max(0.01, timeout)) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                _ = exited.wait(timeout: .now() + 0.5)
            }
        }
        return SMBCommandResult(status: process.isRunning ? -1 : process.terminationStatus, timedOut: timedOut)
    }
}

struct SMBMountLease: Hashable {
    let sourceID: UUID
    let id: UUID
}

final class SMBMountManager: @unchecked Sendable {
    private struct ExpectedSource: Equatable {
        let host: String
        let port: Int?
        let path: String
        let user: String

        init(url: URL) throws {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "smb", let host = components.host,
                  !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else { throw SMBClient.SMBError.badURL }
            self.host = host.lowercased()
            self.port = components.port
            self.path = Self.normalized(components.path)
            self.user = components.user ?? "guest"
        }

        func matches(_ snapshot: SMBMountSnapshot, at path: String) -> Bool {
            guard snapshot.mountPoint == path, snapshot.fileSystem.lowercased() == "smbfs" else { return false }
            let raw = snapshot.source.hasPrefix("//") ? "smb:" + snapshot.source : snapshot.source
            guard let url = URL(string: raw), let candidate = try? ExpectedSource(url: url) else { return false }
            return candidate == self
        }

        private static func normalized(_ path: String) -> String {
            var path = path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path
        }
    }

    private struct Entry {
        let path: String
        let directory: SMBDirectoryIdentity
        let expected: ExpectedSource
        var mounted: SMBMountSnapshot?
        var uncertainCommand = false
    }

    /// Mutable state is always protected by the manager's registry lock.
    private final class Slot: @unchecked Sendable {
        let queue: DispatchQueue
        var generation: UInt64 = 0
        var sessionHeld = false
        var leases: Set<UUID> = []
        var entry: Entry?
        var error: Error?
        init(id: UUID) { queue = DispatchQueue(label: "dev.brushllm.player.smb.\(id.uuidString)", qos: .utility) }
    }

    private let lock = NSLock()
    private var slots: [UUID: Slot] = [:]
    private let dependencies: SMBMountDependencies
    private let rootPath: String
    private let instanceID: UUID
    private let commandTimeout: TimeInterval

    init(dependencies: SMBMountDependencies, rootPath: String, instanceID: UUID = UUID(), commandTimeout: TimeInterval = 20) {
        self.dependencies = dependencies
        self.rootPath = rootPath
        self.instanceID = instanceID
        self.commandTimeout = commandTimeout
    }

    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
    private func slot(for id: UUID) -> Slot {
        if let slot = slots[id] { return slot }
        let slot = Slot(id: id)
        slots[id] = slot
        return slot
    }

    static func shareURL(source: MediaServerSource, password: String?) throws -> URL {
        guard var components = URLComponents(string: source.baseURL), components.scheme?.lowercased() == "smb",
              components.host != nil, components.query == nil, components.fragment == nil else { throw SMBClient.SMBError.badURL }
        // Set raw credentials once. Pre-encoding here produces p%2540ss.
        components.user = source.username.isEmpty ? "guest" : source.username
        components.password = password ?? ""
        guard let url = components.url else { throw SMBClient.SMBError.badURL }
        return url
    }

    func mount(source: MediaServerSource, password: String?) throws -> String {
        let url = try Self.shareURL(source: source, password: password)
        let expected = try ExpectedSource(url: url)
        let (slot, generation) = locked { () -> (Slot, UInt64) in
            let slot = self.slot(for: source.id)
            slot.generation &+= 1
            slot.sessionHeld = true
            return (slot, slot.generation)
        }
        // Only this server's operation queue waits for the bounded process;
        // the registry lock is never held while waiting or doing filesystem IO.
        return try slot.queue.sync {
            do {
                guard locked({ slot.generation == generation && slot.sessionHeld }) else { throw CancellationError() }
                var entry = locked { slot.entry }
                if let existing = entry {
                    guard !existing.uncertainCommand else { throw SMBClient.SMBError.mountFailed("The previous mount command timed out; its resources were retained") }
                    guard existing.expected == expected else { throw SMBClient.SMBError.inUse }
                    if let mounted = existing.mounted {
                        let now = try dependencies.snapshot(existing.path)
                        if now.mountPoint == existing.path {
                            guard expected.matches(now, at: existing.path), now.identifier == mounted.identifier else { throw SMBClient.SMBError.ownership }
                            guard locked({ slot.generation == generation }) else { throw CancellationError() }
                            return existing.path
                        }
                        // An earlier release may have finished umount after
                        // this reconnect reserved its new generation.
                        var uncovered = existing
                        uncovered.mounted = nil
                        entry = uncovered
                        locked { slot.entry = uncovered }
                    }
                    try verifyUncovered(existing)
                } else {
                    let path = rootPath + "/" + source.id.uuidString + "-" + instanceID.uuidString
                    let identity = try dependencies.createDirectory(path)
                    let created = Entry(path: path, directory: identity, expected: expected, mounted: nil)
                    entry = created
                    locked { slot.entry = created }
                    try verifyUncovered(created)
                }
                guard let pending = entry, locked({ slot.generation == generation }) else { throw CancellationError() }
                let result: SMBCommandResult
                do { result = try dependencies.command("/sbin/mount_smbfs", ["-N", url.absoluteString, pending.path], commandTimeout) }
                catch {
                    try? cleanUncovered(pending, slot: slot, generation: generation)
                    throw SMBClient.SMBError.mountFailed("Could not start the mount command")
                }
                if result.timedOut {
                    var uncertain = pending
                    uncertain.uncertainCommand = true
                    if let snapshot = try? dependencies.snapshot(pending.path), expected.matches(snapshot, at: pending.path) {
                        uncertain.mounted = snapshot
                    }
                    locked { slot.entry = uncertain }
                    throw SMBClient.SMBError.mountFailed("Mount command timed out; its resources were retained")
                }
                let now = try dependencies.snapshot(pending.path)
                if expected.matches(now, at: pending.path) {
                    var mounted = pending
                    mounted.mounted = now
                    locked { slot.entry = mounted }
                    // Even a failing/timed-out command may have mounted the
                    // share. Keep ownership for safe explicit release/retry.
                    guard !result.timedOut, result.status == 0 else { throw SMBClient.SMBError.mountFailed("Mount command failed or timed out") }
                    guard locked({ slot.generation == generation && slot.sessionHeld }) else { throw CancellationError() }
                    locked { slot.error = nil }
                    return pending.path
                }
                try? cleanUncovered(pending, slot: slot, generation: generation)
                throw SMBClient.SMBError.mountFailed(result.timedOut ? "Mount command timed out" : "The expected share was not mounted")
            } catch {
                locked { slot.error = error }
                throw error
            }
        }
    }

    /// Nonblocking consumer references. Browser navigation never releases the
    /// session hold; playback/queue consumers may additionally hold a lease.
    func retain(source: MediaServerSource) -> SMBMountLease {
        locked {
            let slot = self.slot(for: source.id)
            let lease = SMBMountLease(sourceID: source.id, id: UUID())
            slot.leases.insert(lease.id)
            slot.generation &+= 1
            return lease
        }
    }

    func release(_ lease: SMBMountLease) {
        let request: (Slot, UInt64)? = locked {
            guard let slot = slots[lease.sourceID], slot.leases.remove(lease.id) != nil else { return nil }
            slot.generation &+= 1
            return (slot, slot.generation)
        }
        if let (slot, generation) = request { scheduleRelease(slot, generation: generation) }
    }

    func releaseSession(source: MediaServerSource) {
        let request: (Slot, UInt64)? = locked {
            guard let slot = slots[source.id] else { return nil }
            slot.sessionHeld = false
            slot.generation &+= 1
            return (slot, slot.generation)
        }
        if let (slot, generation) = request { scheduleRelease(slot, generation: generation) }
    }

    func releaseAllSessions() {
        let requests = locked {
            slots.values.map { slot -> (Slot, UInt64) in
                slot.sessionHeld = false
                slot.generation &+= 1
                return (slot, slot.generation)
            }
        }
        for (slot, generation) in requests { scheduleRelease(slot, generation: generation) }
    }

    /// Gives already-queued releases a bounded opportunity during app exit.
    /// Returning false means operations/consumer leases remain; never force
    /// unmount or discard their ownership records to meet the deadline.
    func shutdown(timeout: TimeInterval) async -> Bool {
        guard timeout.isFinite, timeout > 0 else { return false }
        releaseAllSessions()
        let all = locked { Array(slots.values) }
        let group = DispatchGroup()
        for slot in all {
            group.enter()
            slot.queue.async { group.leave() }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                let drained = group.wait(timeout: .now() + timeout) == .success
                continuation.resume(returning: drained && locked { all.allSatisfy { $0.entry == nil && $0.leases.isEmpty } })
            }
        }
    }

    func lastError(for source: MediaServerSource) -> Error? { locked { slots[source.id]?.error } }

    /// Test synchronization, never used by production/UI shutdown.
    func waitForPendingOperations(source: MediaServerSource) { let slot = locked { slots[source.id] }; slot?.queue.sync {} }

    private func scheduleRelease(_ slot: Slot, generation: UInt64) {
        slot.queue.async { [self] in
            guard locked({ slot.generation == generation && !slot.sessionHeld && slot.leases.isEmpty }),
                  let entry = locked({ slot.entry }) else { return }
            do {
                guard !entry.uncertainCommand else { throw SMBClient.SMBError.mountFailed("A timed-out operation may still own this directory") }
                let before = try dependencies.snapshot(entry.path)
                if let mounted = entry.mounted {
                    if before.mountPoint == entry.path {
                        guard entry.expected.matches(before, at: entry.path), before.identifier == mounted.identifier else { throw SMBClient.SMBError.ownership }
                        guard locked({ slot.generation == generation && !slot.sessionHeld && slot.leases.isEmpty }) else { return }
                        // Registry/ownership remain until the exact original
                        // mount is proven absent. No force-unmount retry.
                        let result = try dependencies.command("/sbin/umount", [entry.path], commandTimeout)
                        if result.timedOut {
                            var uncertain = entry
                            uncertain.uncertainCommand = true
                            locked { slot.entry = uncertain }
                            throw SMBClient.SMBError.unmountFailed
                        }
                        let after = try dependencies.snapshot(entry.path)
                        guard !result.timedOut, result.status == 0, after.mountPoint != entry.path else { throw SMBClient.SMBError.unmountFailed }
                    }
                } else if before.mountPoint == entry.path {
                    throw SMBClient.SMBError.ownership
                }
                // A consumer arriving during umount prevents old cleanup.
                // It will remount on this queue if the old mount vanished.
                try cleanUncovered(entry, slot: slot, generation: generation)
                locked { if slot.generation == generation { slot.error = nil } }
            } catch { locked { slot.error = error } }
        }
    }

    private func verifyUncovered(_ entry: Entry) throws {
        let snapshot = try dependencies.snapshot(entry.path)
        guard snapshot.mountPoint != entry.path,
              try dependencies.directoryIdentity(entry.path) == entry.directory else { throw SMBClient.SMBError.ownership }
    }

    private func cleanUncovered(_ entry: Entry, slot: Slot, generation: UInt64) throws {
        guard locked({ slot.generation == generation }) else { return }
        try verifyUncovered(entry)
        // Recheck after lstat as well. rmdir itself is nonrecursive and will
        // refuse a mount/nonempty directory even if an external race occurs.
        guard try dependencies.snapshot(entry.path).mountPoint != entry.path else { return }
        try locked {
            guard slot.generation == generation else { return }
            // The tiny nonrecursive cleanup and registry commit are atomic
            // with new reservations. No process wait occurs under this lock.
            try dependencies.removeEmptyDirectory(entry.path)
            slot.entry = nil
        }
    }
}

enum SMBClient {
    enum SMBError: LocalizedError {
        case badURL, mountFailed(String), notMounted, ownership, inUse, unmountFailed, badPath
        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid SMB share URL"
            case .mountFailed(let detail): return "Could not mount the share: \(detail)"
            case .notMounted: return "The share is not mounted"
            case .ownership: return "The mount point changed or is not owned by this session"
            case .inUse: return "Release the previous share before reconnecting with different credentials"
            case .unmountFailed: return "The share could not be unmounted; its directory was retained"
            case .badPath: return "Invalid path inside the share"
            }
        }
    }

    private static let manager = SMBMountManager(dependencies: .live, rootPath:
        (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory())
        + "/BrushLLM Player/Mounts")

    static func mount(source: MediaServerSource, password: String?) throws -> String { try manager.mount(source: source, password: password) }
    static func retain(source: MediaServerSource) -> SMBMountLease { manager.retain(source: source) }
    static func release(_ lease: SMBMountLease) { manager.release(lease) }
    static func releaseSession(source: MediaServerSource) { manager.releaseSession(source: source) }
    static func unmount(source: MediaServerSource) { manager.releaseSession(source: source) }
    static func unmountAll() { manager.releaseAllSessions() }
    static func shutdown(timeout: TimeInterval = 3) async -> Bool { await manager.shutdown(timeout: timeout) }
    static func lastError(for source: MediaServerSource) -> Error? { manager.lastError(for: source) }

    static func list(source: MediaServerSource, path: String, password: String?) throws -> [MediaItem] {
        let mountPoint = try mount(source: source, password: password)
        let absolute = try absolutePath(mountPoint: mountPoint, path: path)
        let entries = try FileManager.default.contentsOfDirectory(atPath: absolute)
        return try entries.filter { !$0.hasPrefix(".") }.map { entry in
            let childPath = (path as NSString).appendingPathComponent(entry)
            let childAbsolute = try absolutePath(mountPoint: mountPoint, path: childPath)
            let attributes = try FileManager.default.attributesOfItem(atPath: childAbsolute)
            return MediaItem(id: childPath, name: entry, isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory,
                             size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                             modifiedAt: attributes[.modificationDate] as? Date)
        }
    }

    static func playbackURL(source: MediaServerSource, path: String, password: String?) throws -> URL {
        let mountPoint = try mount(source: source, password: password)
        return URL(fileURLWithPath: try absolutePath(mountPoint: mountPoint, path: path))
    }

    private static func absolutePath(mountPoint: String, path: String) throws -> String {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !relative.contains("\0"), !relative.split(separator: "/").contains("..") else { throw SMBError.badPath }
        let root = URL(fileURLWithPath: mountPoint).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { throw SMBError.badPath }
        return candidate.path
    }
}
