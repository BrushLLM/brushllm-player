import Foundation
import MediaPlayer

/// System media control: publishes playback state to the macOS Control
/// Center "Now Playing" module and answers its remote commands (plus the
/// hardware media keys), ported from IINA's `NowPlayingInfoManager` and
/// `RemoteCommandController`.
///
/// The app owns exactly one playback-capable `PlayerCore`, so the manager
/// keeps a weak reference to the most recent player that published metadata
/// and forwards every remote command to it; the handlers no-op once that
/// player goes away. IINA deliberately releases the shared Now Playing
/// feature when no media is open (issue #4331) — `endSession()` does the
/// same here.
///
/// All entry points run on the main thread: `PlayerCore`'s event handler
/// delivers there, and `MPRemoteCommandCenter` invokes its targets on the
/// main thread as well.
final class NowPlayingManager {

    /// The shared manager; the app has a single Now Playing session.
    static let shared = NowPlayingManager()

    /// The player remote commands are forwarded to; set whenever a player
    /// publishes metadata. Weak — a stale reference must not keep a torn
    /// down player alive.
    private weak var activePlayer: PlayerCore?

    /// Whether the remote command targets have been registered (once per
    /// process; `activate()` is idempotent).
    private var commandsRegistered = false

    private init() {}

    // MARK: - Remote commands

    /// Registers the remote command handlers with `MPRemoteCommandCenter`.
    /// Called once at app startup (from the playback player's init; headless
    /// test/thumbnail players never activate it).
    func activate() {
        guard !commandsRegistered else { return }
        commandsRegistered = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.forward { if $0.isPaused { $0.togglePlay() } } ?? .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.forward { if !$0.isPaused { $0.togglePlay() } } ?? .commandFailed
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.forward { $0.togglePlay() } ?? .commandFailed
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.forward { $0.playlistNext() } ?? .commandFailed
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.forward { $0.playlistPrevious() } ?? .commandFailed
        }
        // ±30 s skip buttons (and the media keys bound to them).
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            return self?.forward { $0.seek(relative: interval) } ?? .commandFailed
        }
        center.skipBackwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            return self?.forward { $0.seek(relative: -interval) } ?? .commandFailed
        }
        // Scrubber in the Now Playing module.
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            return self?.forward { $0.seek(to: time) } ?? .commandFailed
        }
        DebugLog.log("nowPlaying: remote commands registered")
    }

    /// Runs `action` against the active player (main thread, like the
    /// command handlers themselves); returns the status to report.
    private func forward(_ action: (PlayerCore) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let player = activePlayer else { return .commandFailed }
        action(player)
        return .success
    }

    // MARK: - Now Playing info

    /// Publishes the media's metadata (title, artist, duration) plus the
    /// current playback state. Called when a file is loaded and whenever the
    /// title changes.
    func updateMetadata(player: PlayerCore) {
        writeInfo(player: player, refreshTitle: true)
    }

    /// Publishes the playback state only — rate and elapsed time — while a
    /// file is playing (pause/play switches, seeks, speed changes, the
    /// throttled position updates). An idle player ends the session.
    func updatePlaybackState(player: PlayerCore) {
        writeInfo(player: player, refreshTitle: false)
    }

    /// Releases the shared Now Playing feature: clears the published info and
    /// reports playback stopped. Called when the player goes idle, so the
    /// module returns to other apps instead of showing a stale entry.
    func endSession() {
        guard activePlayer != nil else { return }
        activePlayer = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        DebugLog.log("nowPlaying: session ended")
    }

    /// Writes the info dictionary. When paused the rate must be 0, otherwise
    /// the Now Playing slider shows a wrong time (IINA hit the same issue);
    /// the title is only recomputed when requested, keeping mid-playback
    /// state updates cheap.
    private func writeInfo(player: PlayerCore, refreshTitle: Bool) {
        guard !player.isIdle else {
            endSession()
            return
        }
        activePlayer = player

        let center = MPNowPlayingInfoCenter.default()
        var info = center.nowPlayingInfo ?? [:]
        if refreshTitle || info[MPMediaItemPropertyTitle] == nil {
            info[MPMediaItemPropertyTitle] =
                player.mediaTitle.isEmpty ? player.fileName : player.mediaTitle
            info[MPMediaItemPropertyArtist] = ""
        }
        info[MPMediaItemPropertyPlaybackDuration] = player.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPaused ? 0.0 : player.speed
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        center.nowPlayingInfo = info
        center.playbackState = player.isPaused ? .paused : .playing
    }
}
