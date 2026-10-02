import Foundation
import Combine
import AppKit

/// App-wide user settings, persisted in UserDefaults and applied to mpv on change.
///
/// All access happens on the main thread (SwiftUI bindings and app startup).
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let defaults: UserDefaults

    // MARK: Keys

    private enum Key {
        static let language = "language"
        static let volume = "volume"
        static let muted = "muted"
        static let hardwareDecoding = "hardwareDecoding"
        static let loopMode = "loopMode"
        static let aspectMode = "aspectMode"
        static let aspectOverride = "aspectOverride"
        static let screenshotDirectory = "screenshotDirectory"
        static let recordingDirectory = "recordingDirectory"
        static let autoLoadSubtitles = "autoLoadSubtitles"
        static let userAgent = "userAgent"
        static let readaheadSecs = "readaheadSecs"
        static let bufferMB = "bufferMB"
    }

    // MARK: Settings

    /// nil = follow system language; otherwise a code like "zh-Hans".
    @Published var language: String? {
        didSet {
            defaults.set(language ?? "", forKey: Key.language)
            // Steer the bundle's localization resolution so AppKit's
            // standard menus (File/Edit/…) match; takes effect next launch.
            // This must happen BEFORE setLanguage: the app-domain
            // AppleLanguages override also redirects
            // Locale.preferredLanguages for this process, so a stale
            // override would otherwise win when resolving "system".
            if let language {
                defaults.set([language], forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
            Localization.setLanguage(language)
        }
    }

    @Published var defaultVolume: Double {
        didSet { defaults.set(defaultVolume, forKey: Key.volume) }
    }

    @Published var startMuted: Bool {
        didSet { defaults.set(startMuted, forKey: Key.muted) }
    }

    @Published var hardwareDecoding: Bool {
        didSet {
            defaults.set(hardwareDecoding, forKey: Key.hardwareDecoding)
            // Applies to running players immediately (mpv re-initializes the
            // decoder when the hwdec property changes).
            NotificationCenter.default.post(
                name: .brushPlayerHWDecChanged,
                object: nil,
                userInfo: ["enabled": hardwareDecoding]
            )
        }
    }

    @Published var loopMode: LoopMode {
        didSet { defaults.set(loopMode.rawValue, forKey: Key.loopMode) }
    }

    @Published var aspectMode: PlayerCore.AspectMode {
        didSet { defaults.set(aspectMode.rawValue, forKey: Key.aspectMode) }
    }

    @Published var aspectOverride: String? {
        didSet { defaults.set(aspectOverride ?? "", forKey: Key.aspectOverride) }
    }

    /// Where screenshots are saved (default: ~/Pictures/BrushLLM Player).
    @Published var screenshotDirectory: String {
        didSet { defaults.set(screenshotDirectory, forKey: Key.screenshotDirectory) }
    }

    /// Where recordings are saved (default: ~/Movies/BrushLLM Player).
    @Published var recordingDirectory: String {
        didSet { defaults.set(recordingDirectory, forKey: Key.recordingDirectory) }
    }

    /// Auto-load subtitle files matching the video's name from its folder.
    /// Off by default: the directory scan can stall on large or cloud-synced
    /// folders.
    @Published var autoLoadSubtitles: Bool {
        didSet {
            defaults.set(autoLoadSubtitles, forKey: Key.autoLoadSubtitles)
            NotificationCenter.default.post(
                name: .brushPlayerSubAutoChanged,
                object: nil,
                userInfo: ["enabled": autoLoadSubtitles]
            )
        }
    }

    /// User-Agent sent with every network request. A browser UA by default:
    /// many CDNs reject the default "libmpv"/"Lavf" agents outright.
    @Published var userAgent: String {
        didSet {
            defaults.set(userAgent, forKey: Key.userAgent)
            NotificationCenter.default.post(
                name: .brushPlayerUserAgentChanged,
                object: nil,
                userInfo: ["agent": userAgent]
            )
        }
    }

    /// The built-in browser User-Agent (also the default for `userAgent`).
    static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// How many seconds the demuxer thread buffers ahead of playback.
    @Published var readaheadSeconds: Double {
        didSet {
            defaults.set(readaheadSeconds, forKey: Key.readaheadSecs)
            NotificationCenter.default.post(
                name: .brushPlayerReadaheadChanged,
                object: nil,
                userInfo: ["secs": readaheadSeconds]
            )
        }
    }

    /// Demuxer buffer size in MiB.
    @Published var bufferMB: Double {
        didSet {
            defaults.set(bufferMB, forKey: Key.bufferMB)
            NotificationCenter.default.post(
                name: .brushPlayerBufferChanged,
                object: nil,
                userInfo: ["mib": bufferMB]
            )
        }
    }

    // MARK: - Init

    private init() {
        defaults = UserDefaults.standard
        let languageCode = defaults.string(forKey: Key.language)
        language = (languageCode?.isEmpty ?? true) ? nil : languageCode
        defaultVolume = defaults.object(forKey: Key.volume) as? Double ?? 100
        startMuted = defaults.bool(forKey: Key.muted)
        hardwareDecoding = defaults.object(forKey: Key.hardwareDecoding) as? Bool ?? true
        loopMode = LoopMode(rawValue: defaults.string(forKey: Key.loopMode) ?? "") ?? .off
        aspectMode = PlayerCore.AspectMode(rawValue: defaults.string(forKey: Key.aspectMode) ?? "") ?? .fit
        let override = defaults.string(forKey: Key.aspectOverride)
        aspectOverride = (override?.isEmpty ?? true) ? nil : override
        let pictures = (NSSearchPathForDirectoriesInDomains(.picturesDirectory, .userDomainMask, true).first
                        ?? NSTemporaryDirectory()) + "/BrushLLM Player"
        let movies = (NSSearchPathForDirectoriesInDomains(.moviesDirectory, .userDomainMask, true).first
                      ?? NSTemporaryDirectory()) + "/BrushLLM Player"
        let savedScreenshotDir = defaults.string(forKey: Key.screenshotDirectory)
        screenshotDirectory = (savedScreenshotDir?.isEmpty ?? true) ? pictures : savedScreenshotDir!
        let savedRecordingDir = defaults.string(forKey: Key.recordingDirectory)
        recordingDirectory = (savedRecordingDir?.isEmpty ?? true) ? movies : savedRecordingDir!
        // On by default: matching sidecar subtitles load automatically.
        autoLoadSubtitles = defaults.object(forKey: Key.autoLoadSubtitles) as? Bool ?? true
        let savedUserAgent = defaults.string(forKey: Key.userAgent)
        userAgent = (savedUserAgent?.isEmpty ?? true) ? Self.defaultUserAgent : savedUserAgent!
        readaheadSeconds = defaults.object(forKey: Key.readaheadSecs) as? Double ?? 20
        bufferMB = defaults.object(forKey: Key.bufferMB) as? Double ?? 96
        Localization.setLanguage(language)
    }

    /// Applies persisted settings to a player.
    func applyTo(player: PlayerCore) {
        player.volume = defaultVolume
        player.isMuted = startMuted
        player.setLoopMode(loopMode)
        player.aspectMode = aspectMode
        player.aspectOverride = aspectOverride
    }
}

extension Notification.Name {
    static let brushPlayerHWDecChanged = Notification.Name("dev.brushllm.player.hwdecChanged")
    static let brushPlayerSubAutoChanged = Notification.Name("dev.brushllm.player.subAutoChanged")
    static let brushPlayerUserAgentChanged = Notification.Name("dev.brushllm.player.userAgentChanged")
    static let brushPlayerReadaheadChanged = Notification.Name("dev.brushllm.player.readaheadChanged")
    static let brushPlayerBufferChanged = Notification.Name("dev.brushllm.player.bufferChanged")
}
