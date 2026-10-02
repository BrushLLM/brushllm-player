import Foundation

/// Development diagnostics that survive every launch method (stdout is buffered
/// or discarded for GUI apps). Writes to /tmp/brushllm-debug.log.
///
/// Release builds compile the logging out: each line opened, wrote and closed
/// the file, which was measurable during playback (an 8s play wrote 245 lines).
enum DebugLog {
#if DEBUG
    private static let url = URL(fileURLWithPath: "/tmp/brushllm-debug.log")

    static func log(_ message: String) {
        let line = "\(Date()) | \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
#else
    static func log(_ message: String) {}
#endif
}
