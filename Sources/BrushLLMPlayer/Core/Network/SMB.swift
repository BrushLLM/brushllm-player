import Foundation

/// SMB client via macOS's native `mount_smbfs`: the share is mounted into a
/// per-server directory under the app's support folder (no administrator
/// privileges needed — the mount point is user-owned), then browsed and
/// played through ordinary local file paths.
///
/// Mounts are tracked in a registry and unmounted when the user leaves the
/// server, switches to another one, or the app terminates.
enum SMBClient {

    enum SMBError: LocalizedError {
        case badURL
        case mountFailed(String)
        case notMounted

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid SMB share URL"
            case .mountFailed(let detail): return "Could not mount the share: \(detail)"
            case .notMounted: return "The share is not mounted"
            }
        }
    }

    /// source.id.uuidString → mount point path.
    private static var mounts: [String: String] = [:]
    private static let lock = NSLock()

    /// The per-server mount directory under Application Support.
    private static func mountDirectory(for source: MediaServerSource) -> String {
        let support = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
                       ?? NSTemporaryDirectory()) + "/BrushLLM Player/Mounts"
        return support + "/" + source.id.uuidString
    }

    /// Mounts the share (if needed) and returns the local mount point.
    /// `baseURL` has the form `smb://host/share`.
    static func mount(source: MediaServerSource, password: String?) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let mountPoint = mountDirectory(for: source)
        if isMounted(mountPoint) {
            return mountPoint
        }

        // Create the user-owned mount point.
        try? FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        // Build the smb:// URL with embedded credentials. mount_smbfs wants
        // them percent-encoded in the URL; an empty username mounts as guest.
        guard var components = URLComponents(string: source.baseURL) else { throw SMBError.badURL }
        if !source.username.isEmpty {
            components.user = source.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
            components.password = (password ?? "").addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed)
        }
        guard let shareURL = components.url else { throw SMBError.badURL }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount_smbfs")
        // -N: no password prompt (credentials come from the URL or guest).
        process.arguments = ["-N", shareURL.absoluteString, mountPoint]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0, isMounted(mountPoint) else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            // Clean up the empty mount directory so a retry starts fresh.
            try? FileManager.default.removeItem(atPath: mountPoint)
            throw SMBError.mountFailed(detail)
        }
        mounts[source.id.uuidString] = mountPoint
        return mountPoint
    }

    /// Unmounts the given server's share (fire-and-forget, utility queue).
    static func unmount(source: MediaServerSource) {
        lock.lock()
        let mountPoint = mounts.removeValue(forKey: source.id.uuidString)
        lock.unlock()
        guard let mountPoint else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/umount")
            process.arguments = [mountPoint]
            try? process.run()
            process.waitUntilExit()
            // Remove the now-empty mount directory.
            try? FileManager.default.removeItem(atPath: mountPoint)
        }
    }

    /// Unmounts everything (app termination).
    static func unmountAll() {
        lock.lock()
        let all = Array(mounts.values)
        mounts.removeAll()
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            for mountPoint in all {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/sbin/umount")
                process.arguments = [mountPoint]
                try? process.run()
                process.waitUntilExit()
                try? FileManager.default.removeItem(atPath: mountPoint)
            }
        }
    }

    private static func isMounted(_ path: String) -> Bool {
        // A mounted volume reports a device in its stat attributes.
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let systemNumber = attrs[.systemNumber] as? NSNumber else { return false }
        return systemNumber.intValue != 0
    }

    // MARK: - Browsing

    /// Lists a directory relative to the share root. `path` uses "/" as
    /// separator and "" for the root.
    static func list(source: MediaServerSource, path: String, password: String?) throws -> [MediaItem] {
        let mountPoint = try mount(source: source, password: password)
        let absolute = absolutePath(mountPoint: mountPoint, path: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: absolute) else {
            return []
        }
        return entries
            .filter { !$0.hasPrefix(".") }
            .map { entry in
                let childPath = (path as NSString).appendingPathComponent(entry)
                let childAbsolute = absolutePath(mountPoint: mountPoint, path: childPath)
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: childAbsolute, isDirectory: &isDirectory)
                let attrs = try? FileManager.default.attributesOfItem(atPath: childAbsolute)
                let size = (attrs?[.size] as? Int64) ?? 0
                let modified = attrs?[.modificationDate] as? Date
                return MediaItem(id: childPath, name: entry, isDirectory: isDirectory.boolValue, size: size, modifiedAt: modified)
            }
    }

    /// Local file URL for playback (the player's local-file branch handles it).
    static func playbackURL(source: MediaServerSource, path: String, password: String?) throws -> URL {
        let mountPoint = try mount(source: source, password: password)
        return URL(fileURLWithPath: absolutePath(mountPoint: mountPoint, path: path))
    }

    private static func absolutePath(mountPoint: String, path: String) -> String {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return mountPoint + "/" + normalized
    }
}
