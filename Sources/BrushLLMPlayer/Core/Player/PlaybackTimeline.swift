import Foundation
import Combine

/// Display-only position. The player retains exact event positions separately
/// for history and seeking; continuous progress needs at most ten updates/sec.
final class PlaybackTimeline: ObservableObject {
    @Published private(set) var position: Double = 0
    private var lastPublication = ProcessInfo.processInfo.systemUptime

    func update(_ value: Double, force: Bool = false,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard value.isFinite else { return }
        let value = max(0, value)
        guard value != position else { return }
        guard force || value < position || value - position >= 1 || now - lastPublication >= 0.1 else { return }
        lastPublication = now
        position = value
    }
}
