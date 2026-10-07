import Foundation
import Darwin

final class DiscImageResource: @unchecked Sendable {
    typealias Selection = (path: String, vobs: [String], edl: URL?)
    typealias Runner = @Sendable ([String], CommandControl) throws -> CommandResult
    typealias Selector = @Sendable (URL) throws -> Selection

    /// The executor returns partial output on cancellation/timeout too. Only a
    /// complete plist naming our exact private mount point proves ownership.
    struct CommandResult: Sendable {
        var output: Data = Data()
        var status: Int32 = 0
        var cancelled = false
        var timedOut = false
        var reaped = true
    }

    final class CommandControl: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var limit: TimeInterval
        private var cancellationCleanup: (@Sendable () -> Void)?

        init(deadline: TimeInterval) { limit = deadline }
        var state: (cancelled: Bool, deadline: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            return (cancelled, limit)
        }
        func cancel(deadline: TimeInterval? = nil) {
            lock.lock()
            cancelled = true
            limit = min(limit, deadline ?? DiscImageResource.now + 3)
            let cleanup = cancellationCleanup
            lock.unlock()
            cleanup?()
        }
        fileprivate func releaseOnCancellation(_ resource: DiscImageResource) {
            lock.lock()
            cancellationCleanup = { [weak resource] in resource?.release() }
            let cleanup = cancelled ? cancellationCleanup : nil
            lock.unlock()
            cleanup?()
        }
    }

    /// One registry tracks attach BEFORE it is dispatched and keeps busy owned
    /// resources retryable. Tests inject a private registry, never real mounts.
    final class Lifecycle: @unchecked Sendable {
        private let condition = NSCondition()
        private var mounts: [UUID: CommandControl] = [:]
        private var resources: [UUID: DiscImageResource] = [:]
        private var pendingReleases: Set<UUID> = []
        private var unresolvedDirectories: Set<String> = []
        private var exitDeadline: TimeInterval?

        fileprivate func begin(_ id: UUID, control: CommandControl) throws {
            condition.lock(); defer { condition.unlock() }
            guard exitDeadline == nil else { throw CancellationError() }
            mounts[id] = control
            condition.broadcast()
        }
        fileprivate func finish(_ id: UUID) {
            condition.lock(); mounts.removeValue(forKey: id); condition.broadcast(); condition.unlock()
        }
        fileprivate func register(_ resource: DiscImageResource) {
            condition.lock(); resources[resource.id] = resource; condition.broadcast(); condition.unlock()
        }
        fileprivate func requested(_ id: UUID) {
            condition.lock()
            if resources[id] != nil { pendingReleases.insert(id) }
            condition.broadcast(); condition.unlock()
        }
        fileprivate func released(_ id: UUID) {
            condition.lock()
            // Release outside the registry lock: resource deinit calls release.
            let resource = resources.removeValue(forKey: id)
            pendingReleases.remove(id)
            condition.broadcast(); condition.unlock()
            withExtendedLifetime(resource) {}
        }
        fileprivate func unresolved(_ directory: URL) {
            condition.lock(); unresolvedDirectories.insert(directory.path); condition.broadcast(); condition.unlock()
        }
        fileprivate func deadline(_ fallback: TimeInterval) -> TimeInterval {
            condition.lock(); defer { condition.unlock() }
            return min(fallback, exitDeadline ?? fallback)
        }
        fileprivate var isExiting: Bool {
            condition.lock(); defer { condition.unlock() }
            return exitDeadline != nil
        }
        func cancelPendingMounts(timeout: TimeInterval = 3) {
            condition.lock()
            let deadline = min(exitDeadline ?? .infinity, DiscImageResource.now + max(0, timeout))
            exitDeadline = deadline
            let controls = Array(mounts.values)
            condition.broadcast(); condition.unlock()
            for control in controls { control.cancel(deadline: deadline) }
        }
        fileprivate func requestAllReleases() {
            condition.lock(); let owned = Array(resources.values); condition.unlock()
            for resource in owned { resource.release() }
        }
        fileprivate func retryRequestedReleases() {
            condition.lock()
            let owned = pendingReleases.compactMap { resources[$0] }
            condition.unlock()
            for resource in owned { resource.release() }
        }
        fileprivate func wait(until deadline: TimeInterval) -> Bool {
            condition.lock(); defer { condition.unlock() }
            while !mounts.isEmpty || !pendingReleases.isEmpty {
                let remaining = deadline - DiscImageResource.now
                if remaining <= 0 { return false }
                _ = condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.05)))
            }
            return unresolvedDirectories.isEmpty
        }
    }

    final class ConsumerLease: @unchecked Sendable {
        private let lock = NSLock()
        private var resource: DiscImageResource?
        fileprivate init(_ resource: DiscImageResource) { self.resource = resource }
        /// Synchronous, idempotent. The thumbnail owner calls this only AFTER
        /// ThumbnailMPV.shutdown has drained its processing queue/loaded file.
        func release() {
            lock.lock(); let owner = resource; resource = nil; lock.unlock()
            owner?.releaseConsumer()
        }
        deinit { release() }
    }

    let streamPath: String
    let vobPaths: [String]
    private let id = UUID()
    private let device: String
    private let mountDirectory: URL
    private let edlURL: URL?
    private let runner: Runner
    private let lifecycle: Lifecycle
    private let lock = NSLock()
    private var consumers = 0
    private var releaseRequested = false
    private var cleanupRunning = false
    private var released = false
    private static let workQueue = DispatchQueue(label: "dev.brushllm.player.disc", qos: .utility, attributes: .concurrent)
    private static let lifecycle = Lifecycle()
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private init(device: String, mountDirectory: URL, selection: Selection,
                 runner: @escaping Runner, lifecycle: Lifecycle) {
        self.device = device
        self.mountDirectory = mountDirectory
        streamPath = selection.path
        vobPaths = selection.vobs
        edlURL = selection.edl
        self.runner = runner
        self.lifecycle = lifecycle
        lifecycle.register(self)
    }

    static func mount(_ path: String) async throws -> DiscImageResource {
        try await mount(path, lifecycle: lifecycle, runner: { try run($0, $1) }, selector: { try selectMedia(at: $0) })
    }

    /// Injection is per operation/registry, so tests cannot change the global
    /// application's runner or run hdiutil by accident.
    static func mount(_ path: String, lifecycle: Lifecycle, runner: @escaping Runner,
                      selector: @escaping Selector, timeout: TimeInterval = 30) async throws -> DiscImageResource {
        let id = UUID()
        let control = CommandControl(deadline: now + max(0, timeout))
        try lifecycle.begin(id, control: control)
        let resource = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                workQueue.async {
                    let result = Result {
                        try performMount(path, lifecycle: lifecycle, runner: runner, selector: selector, control: control)
                    }
                    // A cancelled operation's owned detach has already been
                    // registered before removing the in-flight attach entry.
                    lifecycle.finish(id)
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            control.cancel()
        }
        if Task.isCancelled { resource.release(); throw CancellationError() }
        return resource
    }

    private static func performMount(_ path: String, lifecycle: Lifecycle, runner: @escaping Runner,
                                     selector: Selector, control: CommandControl) throws -> DiscImageResource {
        guard !control.state.cancelled else { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brushplayer-disc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var ownedDevice: String?
        var resource: DiscImageResource?
        do {
            let result = try runner(["attach", path, "-nobrowse", "-readonly", "-plist", "-mountpoint", directory.path], control)
            ownedDevice = parseOwnedDevice(result.output, directory: directory)
            if !result.reaped { lifecycle.unresolved(directory) }
            guard !result.cancelled, !control.state.cancelled, !lifecycle.isExiting else { throw CancellationError() }
            guard !result.timedOut, result.reaped, result.status == 0, let device = ownedDevice else {
                throw CocoaError(.fileReadUnknown)
            }
            let selection = try selector(directory)
            let mounted = DiscImageResource(device: device, mountDirectory: directory, selection: selection,
                                            runner: runner, lifecycle: lifecycle)
            resource = mounted
            control.releaseOnCancellation(mounted)
            guard !control.state.cancelled, !lifecycle.isExiting else { throw CancellationError() }
            return mounted
        } catch {
            if let resource { resource.release() }
            else if let device = ownedDevice {
                // Even failed/cancelled attach can prove ownership in its plist.
                let mounted = DiscImageResource(device: device, mountDirectory: directory,
                    selection: ("", [], nil), runner: runner, lifecycle: lifecycle)
                mounted.release()
            } else {
                // A timed-out command is NOT proof of a device identity. Never
                // guess /dev/disk*, detach other entities, or remove recursively.
                if directory.path.withCString({ rmdir($0) }) != 0 { lifecycle.unresolved(directory) }
            }
            throw error
        }
    }

    private static func parseOwnedDevice(_ data: Data, directory: URL) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        let expected = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let owned = entities.compactMap { entity -> String? in
            guard let path = entity["mount-point"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == expected,
                  let device = entity["dev-entry"] as? String, device.hasPrefix("/dev/"),
                  !device.contains("\n"), !device.contains("\0") else { return nil }
            return device
        }
        return owned.count == 1 ? owned[0] : nil
    }

    static func selectMedia(at directory: URL) throws -> Selection {
        let fm = FileManager.default
        let streams = directory.appendingPathComponent("BDMV/STREAM")
        if let files = try? fm.contentsOfDirectory(at: streams, includingPropertiesForKeys: [.fileSizeKey]) {
            let candidates = files.filter { ["m2ts", "mts"].contains($0.pathExtension.lowercased()) }
            if let main = candidates.max(by: { size($0) < size($1) }) { return (main.path, [], nil) }
        }
        let videoTS = directory.appendingPathComponent("VIDEO_TS")
        let files = try fm.contentsOfDirectory(at: videoTS, includingPropertiesForKeys: [.fileSizeKey])
        var titles: [String: [(Int, URL)]] = [:]
        for file in files where file.pathExtension.lowercased() == "vob" {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard parts.count == 3, parts[0].uppercased() == "VTS", let sequence = Int(parts[2]), sequence > 0 else { continue }
            titles[String(parts[0]) + "_" + parts[1], default: []].append((sequence, file))
        }
        guard let title = titles.max(by: { lhs, rhs in
            lhs.value.reduce(0) { $0 + size($1.1) } < rhs.value.reduce(0) { $0 + size($1.1) }
        }) else { throw CocoaError(.fileReadNoSuchFile) }
        let vobs = title.value.sorted { $0.0 < $1.0 }.map { $0.1.path }
        let edl = fm.temporaryDirectory.appendingPathComponent("brushplayer-disc-\(UUID().uuidString).edl")
        let entries = vobs.map { "%\($0.utf8.count)%\($0)" }.joined(separator: "\n")
        try ("# mpv EDL v0\n" + entries + "\n").write(to: edl, atomically: true, encoding: .utf8)
        return (edl.path, vobs, edl)
    }

    func retainConsumer() -> ConsumerLease? {
        lock.lock(); defer { lock.unlock() }
        guard !releaseRequested, !released else { return nil }
        consumers += 1
        return ConsumerLease(self)
    }
    private func releaseConsumer() {
        lock.lock()
        consumers = max(0, consumers - 1)
        let schedule = releaseRequested && consumers == 0 && !cleanupRunning && !released
        if schedule { cleanupRunning = true }
        lock.unlock()
        if schedule { scheduleCleanup() }
    }
    /// Requests unloading; consumers keep the mount and EDL alive. A busy or
    /// failed detach stays registered and calling release again retries it.
    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        releaseRequested = true
        let schedule = consumers == 0 && !cleanupRunning
        if schedule { cleanupRunning = true }
        lock.unlock()
        lifecycle.requested(id)
        if schedule { scheduleCleanup() }
    }
    private func scheduleCleanup() {
        Self.workQueue.async { [self] in
            let control = CommandControl(deadline: lifecycle.deadline(Self.now + 2))
            let result = try? runner(["detach", device, "-quiet"], control)
            let success = result.map { $0.status == 0 && !$0.timedOut && !$0.cancelled && $0.reaped } ?? false
            if success {
                if let edlURL { try? FileManager.default.removeItem(at: edlURL) }
                mountDirectory.path.withCString { _ = rmdir($0) }
            }
            lock.lock(); cleanupRunning = false; released = success; lock.unlock()
            if success { lifecycle.released(id) }
        }
    }

    static func cancelPendingMounts(timeout: TimeInterval = 3) { lifecycle.cancelPendingMounts(timeout: timeout) }
    static func shutdown(timeout: TimeInterval = 3) async -> Bool {
        await shutdown(lifecycle: lifecycle, timeout: timeout)
    }
    static func shutdown(lifecycle: Lifecycle, timeout: TimeInterval = 3) async -> Bool {
        lifecycle.cancelPendingMounts(timeout: timeout)
        lifecycle.requestAllReleases()
        return await waitForCleanup(lifecycle: lifecycle, timeout: timeout)
    }
    static func waitForCleanup(timeout: TimeInterval = 3) async -> Bool {
        await waitForCleanup(lifecycle: lifecycle, timeout: timeout)
    }
    static func waitForCleanup(lifecycle: Lifecycle, timeout: TimeInterval = 3) async -> Bool {
        let deadline = lifecycle.deadline(now + max(0, timeout))
        lifecycle.retryRequestedReleases()
        return await withCheckedContinuation { continuation in
            workQueue.async { continuation.resume(returning: lifecycle.wait(until: deadline)) }
        }
    }

    deinit { release() }
    private static func size(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    /// Direct local posix_spawn + nonblocking stdout + waitpid(WNOHANG), not
    /// Process.run/waitUntilExit or an unbounded read thread. Cancellation kills
    /// the independently owned PID and reserves time for reaping before deadline.
    private static func run(_ arguments: [String], _ control: CommandControl) throws -> CommandResult {
        if control.state.cancelled { return CommandResult(status: -1, cancelled: true) }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        defer { for fd in descriptors where fd >= 0 { close(fd) } }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) != -1 else { throw POSIXError(.EIO) }
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var argv = (["/usr/bin/hdiutil"] + arguments).map { strdup($0) } + [nil]
        defer { for case let pointer? in argv { free(pointer) } }
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for case let pointer? in environment { free(pointer) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, "/usr/bin/hdiutil", &actions, nil, &argv, &environment)
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        close(descriptors[1]); descriptors[1] = -1
        var result = CommandResult()
        var bytes = [UInt8](repeating: 0, count: 8192)
        var status: Int32 = 0
        var killed = false
        var reaped = false
        let reserve = min(0.2, max(0.005, (control.state.deadline - now) * 0.2))
        while true {
            while true {
                let count = read(descriptors[0], &bytes, bytes.count)
                if count <= 0 { break }
                if result.output.count + count > 1024 * 1024 { result.timedOut = true; break }
                result.output.append(contentsOf: bytes.prefix(count))
            }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; break }
            if waited == -1 && errno == ECHILD {
                // Another OS reaper already consumed this child; its PID is no
                // longer ours to signal. Do not risk killing a recycled PID.
                reaped = true; result.timedOut = true; break
            }
            let state = control.state
            result.cancelled = state.cancelled
            if !killed && (state.cancelled || now >= state.deadline - reserve || result.timedOut) {
                result.timedOut = result.timedOut || !state.cancelled
                kill(pid, SIGKILL)
                killed = true
            }
            if now >= state.deadline { break }
            usleep(5_000)
        }
        if !reaped {
            kill(pid, SIGKILL)
            reaped = waitpid(pid, &status, WNOHANG) == pid
        }
        // Drain available complete output only; no child or inherited pipe can
        // force an EOF wait. Unknown partial plists are deliberately not guessed.
        while result.output.count < 1024 * 1024 {
            let count = read(descriptors[0], &bytes, bytes.count)
            if count <= 0 { break }
            result.output.append(contentsOf: bytes.prefix(min(count, 1024 * 1024 - result.output.count)))
        }
        result.reaped = reaped
        result.cancelled = control.state.cancelled
        result.status = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return result
    }
}
