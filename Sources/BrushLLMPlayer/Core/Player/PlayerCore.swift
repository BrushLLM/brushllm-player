import Foundation
import Combine
import AppKit
import AVFoundation
import Libmpv

/// One player instance: owns the `MPVController` and publishes playback state
/// for SwiftUI. All published state is mutated on the main thread only.
final class PlayerCore: ObservableObject, @unchecked Sendable {

    /// Shared reference for scenes that need the single player (settings).
    /// The app keeps exactly one player for its lifetime.
    static var sharedForSettings: PlayerCore!

    let mpv = MPVController()

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Published playback state

    @Published private(set) var isPaused = true
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isIdle = true
    @Published private(set) var mediaTitle: String = ""
    @Published private(set) var fileName: String = ""
    @Published private(set) var hwdecCurrent: String?
    @Published private(set) var isBuffering = false
    @Published private(set) var loadErrorMessage: String?

    /// Track/playlist/chapter data, refreshed on the corresponding property changes.
    @Published private(set) var audioTracks: [TrackInfo] = []
    @Published private(set) var subtitleTracks: [TrackInfo] = []
    @Published private(set) var videoTracks: [TrackInfo] = []
    @Published private(set) var currentAudioTrack: Int?
    @Published private(set) var currentSubtitleTrack: Int?
    @Published private(set) var playlist: [PlaylistItem] = []
    @Published private(set) var currentPlaylistIndex: Int?
    @Published private(set) var chapters: [ChapterInfo] = []
    @Published private(set) var currentChapter: Int?

    /// User-facing settings mirrored into mpv properties.
    @Published var volume: Double = 100 {
        didSet { mpv.setDouble("volume", volume) }
    }
    @Published var isMuted = false {
        didSet { if !isApplyingFromMPV { mpv.setFlag("mute", isMuted) } }
    }
    @Published var speed: Double = 1 {
        didSet { if !isApplyingFromMPV { mpv.setDouble("speed", speed) } }
    }

    @Published private(set) var loopMode: LoopMode = .off {
        didSet { applyLoopMode() }
    }

    /// Aspect handling mode; `fill` tracks the window aspect on resize.
    @Published var aspectMode: AspectMode = .fit {
        didSet { applyAspectMode() }
    }
    @Published var aspectOverride: String? {
        didSet { applyAspectMode() }
    }

    /// True while the user is scrubbing the progress bar; suppresses position
    /// updates from mpv so the knob doesn't fight the gesture.
    var isScrubbing = false

    /// Seconds since the current load started (drives the slow-load hint).
    @Published private(set) var bufferingSeconds: Int = 0
    private var bufferingTimer: Timer?

    /// Window aspect (width/height) fed by the video view for fill mode.
    var windowAspect: CGFloat = 16.0 / 9.0 {
        didSet {
            if aspectMode == .fill { applyAspectMode() }
        }
    }

    /// A-B loop points; nil = unset. mpv seeks to A when playback passes B.
    @Published private(set) var abLoopA: Double?
    @Published private(set) var abLoopB: Double?

    /// Whether the player window floats above other windows.
    @Published var isOnTop = false {
        didSet { applyWindowLevel() }
    }

    /// Audio delay in seconds (positive delays audio).
    @Published var audioDelay: Double = 0 {
        didSet { if !isApplyingFromMPV { mpv.setDouble("audio-delay", audioDelay) } }
    }

    /// Video delay in seconds, exposed as the inverse of mpv's audio-delay.
    @Published var videoDelay: Double = 0 {
        didSet { if !isApplyingFromMPV { mpv.setDouble("audio-delay", -videoDelay) } }
    }

    /// Whether a recording is in progress (mpv `stream-record`).
    @Published private(set) var isRecording = false

    /// Mini floating window mode (small, always-on-top).
    /// True while the window geometry is animating — a drag-resize (from
    /// `VideoView`) OR a fullscreen transition (from the window
    /// notifications). The control bar swaps to a static snapshot for the
    /// duration — SwiftUI re-lays-out its ~100 layers every geometry tick,
    /// and the window server's processing of those updates made the
    /// animation stutter (measured: 12-15 stalls per drag with the live bar
    /// vs 3-5 with a static one). The same flag also drives the GL layer's
    /// asynchronous (vsync-aligned, off-main-thread) drawing.
    @Published private(set) var isLiveResizing = false
    /// Drag-resize active (reported by `VideoView`).
    private var dragResizing = false
    /// Fullscreen transition in flight (reported by the window notifications).
    private var fullscreenAnimating = false

    /// The video area's width when the animation started; sizes the
    /// control-bar snapshot.
    var liveResizeWidth: CGFloat = 900

    /// Called by `VideoView` on drag-resize start/end.
    func setDragResizing(_ resizing: Bool) {
        dragResizing = resizing
        refreshResizingState()
    }

    /// Single source of truth for the "geometry animating" state: a drag or a
    /// fullscreen transition keeps it on. Applying the GL flag here (instead
    /// of in `VideoView`) prevents the two triggers from clobbering each other
    /// mid-fullscreen — the window's internal live-resize notifications fire
    /// and clear within the same runloop tick, which used to switch the async
    /// drawing off again immediately.
    private func refreshResizingState() {
        let active = dragResizing || fullscreenAnimating
        if isLiveResizing != active {
            isLiveResizing = active
        }
        videoLayer?.inLiveResize = active
    }

    @Published var isMiniWindow = false {
        didSet { applyWindowLevel() }
    }

    /// HDR output: switches mpv to PQ transfer (BT.2020 primaries) and enables
    /// EDR with a PQ layer colorspace so the system color-matches the frames.
    @Published var hdrEnabled = false {
        didSet {
            mpv.setString("target-trc", hdrEnabled ? "pq" : "auto")
            mpv.setString("target-prim", hdrEnabled ? "bt.2020" : "auto")
            videoLayer?.setHDR(hdrEnabled)
            DebugLog.log("hdr: \(hdrEnabled ? "on (pq/bt.2020 + EDR)" : "off")")
        }
    }

    // MARK: - Equalizer (lavfi 3-band)

    @Published var eqEnabled = false {
        didSet { applyEqualizer() }
    }
    @Published var eqBass: Double = 0 {
        didSet { applyEqualizer() }
    }
    @Published var eqMid: Double = 0 {
        didSet { applyEqualizer() }
    }
    @Published var eqTreble: Double = 0 {
        didSet { applyEqualizer() }
    }

    private func applyEqualizer() {
        guard eqEnabled else {
            mpv.setString("af", "")
            return
        }
        // FFmpeg's equalizer filter, one band per frequency; mpv keeps the
        // graph inside the lavfi brackets.
        let chain = "lavfi=[equalizer=f=100:t=q:w=1:g=\(eqBass),"
            + "equalizer=f=1000:t=q:w=1:g=\(eqMid),"
            + "equalizer=f=10000:t=q:w=1:g=\(eqTreble)]"
        mpv.setString("af", chain)
    }

    // MARK: - Subtitle styling (applied live)

    @Published var subtitleFontSize: Double = 38 {
        didSet { mpv.setDouble("sub-font-size", subtitleFontSize) }
    }
    @Published var subtitleBorderSize: Double = 2 {
        didSet { mpv.setDouble("sub-border-size", subtitleBorderSize) }
    }
    /// Vertical position, 0–100 (percent of screen height, bottom-anchored).
    @Published var subtitlePosition: Double = 100 {
        didSet { mpv.setDouble("sub-pos", subtitlePosition) }
    }
    @Published var subtitleColorHex: String = "#FFFFFFFF" {
        didSet { mpv.setString("sub-color", subtitleColorHex) }
    }
    @Published var subtitleBorderColorHex: String = "#000000FF" {
        didSet { mpv.setString("sub-border-color", subtitleBorderColorHex) }
    }

    /// The current hover preview thumbnail (generated on demand at the
    /// exact hovered position).
    @Published private(set) var hoverThumbnail: NSImage?

    /// Headless mpv instance for thumbnail generation (all formats).
    private let thumbnailMPV = ThumbnailMPV()

    /// Bookmarks belonging to the file currently playing (drives the progress
    /// bar markers and the bookmark button's lit state).
    @Published private(set) var currentFileBookmarks: [Bookmark] = []

    /// The video view of the frontmost window; set by `VideoViewRepresentable`.
    weak var videoView: VideoView?

    /// The path/URL of the file currently being played (for history/bookmarks).
    private(set) var currentPath: String?

    /// True while applying a property change that CAME FROM mpv: the didSet
    /// write-backs must be suppressed, otherwise every event echoes a
    /// redundant write into mpv — which can deadlock against the core during
    /// file loading (watch-later restore fires such events mid-load).
    private var isApplyingFromMPV = false

    /// Periodic history position updates.
    private var historyTimer: Timer?

    init() {
        Self.sharedForSettings = self
        let settings = AppSettings.shared
        mpv.eventHandler = { [weak self] event in
            self?.handleEvent(event)
        }
        mpv.start(hardwareDecoding: settings.hardwareDecoding)
        settings.applyTo(player: self)

        // Hardware decoding can be toggled in settings while playing; mpv
        // re-initializes the decoder when the property changes.
        NotificationCenter.default.publisher(for: .brushPlayerHWDecChanged)
            .compactMap { $0.userInfo?["enabled"] as? Bool }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.mpv.setString("hwdec", enabled ? "auto-safe" : "no")
                DebugLog.log("hwdec runtime change: \(enabled ? "auto-safe" : "no")")
            }
            .store(in: &cancellables)

        // Subtitle auto-loading can be toggled in settings while playing.
        NotificationCenter.default.publisher(for: .brushPlayerSubAutoChanged)
            .compactMap { $0.userInfo?["enabled"] as? Bool }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.mpv.setString("sub-auto", enabled ? "exact" : "no")
                DebugLog.log("sub-auto runtime change: \(enabled ? "exact" : "no")")
            }
            .store(in: &cancellables)

        // The User-Agent can be edited in the network panel while playing;
        // applies to requests opened afterwards.
        NotificationCenter.default.publisher(for: .brushPlayerUserAgentChanged)
            .compactMap { $0.userInfo?["agent"] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agent in
                self?.mpv.setString("user-agent", agent)
                DebugLog.log("user-agent runtime change: \(agent)")
            }
            .store(in: &cancellables)

        // Demuxer read-ahead and buffer size from the network panel.
        NotificationCenter.default.publisher(for: .brushPlayerReadaheadChanged)
            .compactMap { $0.userInfo?["secs"] as? Double }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] secs in
                self?.mpv.setString("demuxer-readahead-secs", String(Int(secs)))
                DebugLog.log("readahead runtime change: \(Int(secs))s")
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .brushPlayerBufferChanged)
            .compactMap { $0.userInfo?["mib"] as? Double }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mib in
                self?.mpv.setString("demuxer-max-bytes", "\(Int(mib))MiB")
                DebugLog.log("buffer runtime change: \(Int(mib))MiB")
            }
            .store(in: &cancellables)

        observeWindowNotifications()
    }

    deinit {
        bufferingTimer?.invalidate()
        historyTimer?.invalidate()
        PlaybackStore.shared.flush()
        mpv.eventHandler = nil
        mpv.shutdown()
    }

    // MARK: - Actions

    func open(_ url: URL) {
        loadErrorMessage = nil
        resolvedPlaylistURLs.removeAll()
        // Local files play from their path; remote URLs from the full string.
        let target = url.isFileURL ? url.path : url.absoluteString
        DebugLog.log("open: \(target)")
        // ISO images are disc filesystems: route through libbluray (bd://),
        // falling back to the DVD demuxer.
        if url.isFileURL && url.pathExtension.lowercased() == "iso" {
            openDiscImage(at: url.path)
            return
        }
        mpv.command("loadfile", [target, "replace"])
    }

    /// The device node of a disc image we mounted (detached when another
    /// file is opened).
    private var mountedDiscDevice: String?

    /// VOB paths of the currently playing disc EDL — used to probe the real
    /// total duration (mpv's EDL duration estimate is unreliable for VOBs).
    private var discVobPaths: [String]?

    /// Opens a disc image (ISO). MPVKit's libmpv is built without the bd://
    /// protocol handler, so the image is mounted with hdiutil and the main
    /// video stream (BDMV .m2ts / VIDEO_TS .VOB) plays directly.
    private func openDiscImage(at path: String) {
        detachMountedDisc()
        DebugLog.log("open ISO: mounting \(path)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["attach", path, "-nobrowse", "-readonly"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // Output lines look like "/dev/disk4s1\tApple_HFS\t/Volumes/NAME".
                var device = ""
                var mountPoint = ""
                for line in output.split(separator: "\n").reversed() {
                    let parts = line.split(separator: "\t").map(String.init)
                    if parts.count >= 3, parts[2].hasPrefix("/Volumes/") {
                        mountPoint = parts[2]
                        device = parts[0]
                        break
                    }
                }
                DispatchQueue.main.async {
                    self?.mountedDiscDevice = device.isEmpty ? nil : device
                    self?.playMountedDisc(at: mountPoint, isoPath: path)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.loadErrorMessage = L("player.iso-failed", "Could not open the disc image")
                    DebugLog.log("ISO mount failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Plays the main feature from a mounted disc.
    ///
    /// DVD (VIDEO_TS): the movie is split across sequential VOB files
    /// (VTS_XX_1.VOB, VTS_XX_2.VOB, …). VLC-style: find the title set with
    /// the most content and load all its VOBs as a playlist so they play
    /// continuously. Chapter count is read from the IFO's PTT_SRPT table
    /// and chapters are distributed across the total duration.
    ///
    /// Blu-ray (BDMV/STREAM): the main feature is usually the largest
    /// single .m2ts file.
    private func playMountedDisc(at mountPoint: String, isoPath: String) {
        guard !mountPoint.isEmpty, FileManager.default.fileExists(atPath: mountPoint) else {
            loadErrorMessage = L("player.iso-failed", "Could not open the disc image")
            return
        }
        let fm = FileManager.default

        // Blu-ray: largest .m2ts in BDMV/STREAM
        let bdStreamDir = mountPoint + "/BDMV/STREAM"
        if let files = try? fm.contentsOfDirectory(atPath: bdStreamDir) {
            var candidates: [(path: String, size: UInt64)] = []
            for file in files {
                let ext = (file as NSString).pathExtension.lowercased()
                if ext == "m2ts" || ext == "mts" {
                    let size = (try? fm.attributesOfItem(atPath: bdStreamDir + "/" + file)[.size] as? UInt64) ?? 0
                    candidates.append((bdStreamDir + "/" + file, size))
                }
            }
            if let main = candidates.max(by: { $0.size < $1.size }) {
                DebugLog.log("ISO (BD): playing \(main.path) (\(main.size) bytes)")
                mpv.command("loadfile", [main.path, "replace"])
                return
            }
        }

        // DVD: collect sequential VOBs per title set (VTS_XX_Y, Y >= 1)
        let videoTsDir = mountPoint + "/VIDEO_TS"
        if let files = try? fm.contentsOfDirectory(atPath: videoTsDir) {
            // Group VOBs by title set number, sorted by sequence number
            var titleSets: [String: [(seq: Int, path: String, size: UInt64)]] = [:]
            for file in files {
                let ext = (file as NSString).pathExtension.lowercased()
                guard ext == "vob" else { continue }
                // VTS_01_2.VOB → titleSet="VTS_01", seq=2
                let parts = file.split(separator: "_")
                guard parts.count >= 3 else { continue }
                let titleSet = String(parts[0]) + "_" + String(parts[1])
                let seqStr = parts[2].split(separator: ".").first.map(String.init) ?? "0"
                let seq = Int(seqStr) ?? 0
                // Y=0 is the menu VOB, skip it
                guard seq >= 1 else { continue }
                let size = (try? fm.attributesOfItem(atPath: videoTsDir + "/" + file)[.size] as? UInt64) ?? 0
                titleSets[titleSet, default: []].append((seq, videoTsDir + "/" + file, size))
            }
            // Sort each title set by sequence number
            for (key, _) in titleSets {
                titleSets[key]?.sort { $0.seq < $1.seq }
            }
            // Pick the title set with the largest total size (the main movie)
            guard let mainTitle = titleSets.max(by: { lhs, rhs in
                lhs.value.reduce(0, { $0 + $1.size }) < rhs.value.reduce(0, { $0 + $1.size })
            }) else {
                loadErrorMessage = L("player.iso-no-video", "No video found on the disc image")
                DebugLog.log("ISO mounted but no video streams at \(mountPoint)")
                return
            }
            let vobs = mainTitle.value
            DebugLog.log("ISO (DVD): title set \(mainTitle.key), \(vobs.count) VOBs, total \(vobs.reduce(0, { $0 + $1.size })) bytes")
            // Concatenate all VOBs into one seamless video via an EDL file —
            // a single progress bar, a single duration, no gaps between VOBs.
            let edlPath = NSTemporaryDirectory() + "brushplayer_disc.edl"
            var edl = "# mpv EDL v0\n"
            for vob in vobs {
                edl += "\(vob.path)\n"
            }
            do {
                try edl.data(using: .utf8)?.write(to: URL(fileURLWithPath: edlPath))
            } catch {
                DebugLog.log("ISO (DVD): EDL write failed: \(error.localizedDescription)")
                return
            }
            discVobPaths = vobs.map(\.path)
            mpv.command("loadfile", [edlPath, "replace"])
            return
        }

        loadErrorMessage = L("player.iso-no-video", "No video found on the disc image")
        DebugLog.log("ISO mounted but no video streams at \(mountPoint)")
    }

    /// Probes each VOB's duration with AVURLAsset and overrides the total.
    /// mpv's EDL duration for concatenated VOBs is inflated because of
    /// MPEG-2 variable bitrate estimation.
    private func probeDiscDuration(_ vobPaths: [String]) {
        Task.detached(priority: .utility) { [weak self] in
            var total: Double = 0
            for path in vobPaths {
                let asset = AVURLAsset(url: URL(fileURLWithPath: path))
                var duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .invalid)
                // Some VOBs report wildly inflated durations (MPEG-2 stream
                // corruption); a single DVD VOB is at most ~1GB ≈ 1 hour.
                if duration > 3600 {
                    // Estimate from file size: ~2 MB/s MPEG-2 bitrate
                    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                    let estimated = Double(size) / (2.0 * 1024 * 1024)
                    DebugLog.log("ISO (DVD): VOB duration \(Int(duration))s inflated, estimating \(Int(estimated))s from size")
                    duration = estimated
                }
                if duration.isFinite && duration > 0 {
                    total += duration
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, total > 0, total < self.duration else { return }
                DebugLog.log("ISO (DVD): real duration \(Int(total))s (mpv reported \(Int(self.duration))s)")
                self.duration = total
            }
        }
    }

    /// Detaches a previously mounted disc image.
    private func detachMountedDisc() {
        guard let device = mountedDiscDevice else { return }
        mountedDiscDevice = nil
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["detach", device, "-quiet"]
            try? process.run()
        }
    }

    /// Opens the first file and appends the rest to the playlist.
    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        open(first)
        for url in urls.dropFirst() {
            enqueue(url)
        }
    }

    /// Appends to the playlist without interrupting playback.
    func enqueue(_ url: URL) {
        let target = url.isFileURL ? url.path : url.absoluteString
        mpv.command("loadfile", [target, "append"])
    }

    /// Appends many URLs to the playlist. Returns the number enqueued.
    @discardableResult
    func enqueue(_ urls: [URL]) -> Int {
        for url in urls { enqueue(url) }
        return urls.count
    }

    func togglePlay() {
        guard !isIdle else { return }
        DebugLog.log("togglePlay: \(isPaused ? "pause" : "play")")
        mpv.setFlag("pause", !isPaused)
    }

    func seek(to time: Double) {
        guard !isIdle else { return }
        let clamped = duration > 0 ? min(max(time, 0), duration) : time
        mpv.command("seek", [String(format: "%.3f", clamped), "absolute+exact"])
    }

    func seek(relative seconds: Double) {
        guard !isIdle else { return }
        mpv.command("seek", [String(format: "%.3f", seconds), "relative+exact"])
    }

    func stop() {
        mpv.command("stop", ["keep-playlist"])
    }

    // MARK: - Track selection

    func setAudioTrack(_ id: Int?) {
        mpv.setString("aid", id.map(String.init) ?? "no")
    }

    func setSubtitleTrack(_ id: Int?) {
        mpv.setString("sid", id.map(String.init) ?? "no")
    }

    // MARK: - Playlist

    func playlistNext() {
        mpv.command("playlist-next", ["weak"])
    }

    func playlistPrevious() {
        mpv.command("playlist-prev", ["weak"])
    }

    func playPlaylistIndex(_ index: Int) {
        mpv.command("playlist-play-index", [String(index)])
    }

    func removePlaylistIndex(_ index: Int) {
        mpv.command("playlist-remove", [String(index)])
    }

    func movePlaylistItem(from source: Int, to destination: Int) {
        // mpv's playlist-move semantics: move index1 before index2; when moving
        // down, the destination shifts by one after removal.
        var target = destination
        if source < destination { target += 1 }
        mpv.command("playlist-move", [String(source), String(target)])
    }

    func clearPlaylist() {
        mpv.command("playlist-clear")
    }

    func shufflePlaylist() {
        mpv.command("playlist-shuffle")
    }

    // MARK: - Loop

    func setLoopMode(_ mode: LoopMode) {
        loopMode = mode
    }

    // MARK: - A-B loop

    func setABLoopA() {
        mpv.setDouble("ab-loop-a", position)
    }

    func setABLoopB() {
        mpv.setDouble("ab-loop-b", position)
    }

    func clearABLoop() {
        mpv.setString("ab-loop-a", "no")
        mpv.setString("ab-loop-b", "no")
    }

    // MARK: - Frame stepping

    func frameStepForward() {
        mpv.command("frame-step")
    }

    func frameStepBackward() {
        mpv.command("frame-back-step")
    }

    // MARK: - Chapters

    func nextChapter() {
        mpv.command("add", ["chapter", "1"])
    }

    func previousChapter() {
        mpv.command("add", ["chapter", "-1"])
    }

    func seekToChapter(_ index: Int) {
        mpv.setInt("chapter", index)
    }

    // MARK: - Screenshot

    /// The video layer of the frontmost window; set by `VideoViewRepresentable`.
    weak var videoLayer: VideoLayer?

    /// Saves a screenshot of the current frame (window resolution, including
    /// subtitles) to the configured screenshot folder. MPVKit's FFmpeg lacks
    /// image encoders, so the frame is read back from the GL framebuffer.
    func screenshot() {
        let directory = AppSettings.shared.screenshotDirectory
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let path = directory + "/BrushLLMPlayer-" + formatter.string(from: Date()) + ".png"

        guard let videoLayer else {
            DebugLog.log("screenshot: no video layer attached")
            return
        }
        Task { @MainActor in
            guard let image = await videoLayer.captureSnapshot() else {
                DebugLog.log("screenshot: framebuffer capture failed")
                return
            }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                DebugLog.log("screenshot: PNG encoding failed")
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                DebugLog.log("screenshot saved: \(path)")
            } catch {
                DebugLog.log("screenshot write error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - A/V delay

    func resetDelays() {
        audioDelay = 0
        videoDelay = 0
        mpv.setDouble("audio-delay", 0)
    }

    // MARK: - Network playback

    /// Opens a network URL (https media file, m3u8/HLS, …).
    func openURL(_ url: URL) {
        loadErrorMessage = nil
        DebugLog.log("openURL: \(url.absoluteString)")
        mpv.command("loadfile", [url.absoluteString, "replace"])
    }

    // MARK: - External subtitles

    /// Adds an external subtitle file to the current playback.
    func loadExternalSubtitle(_ url: URL) {
        DebugLog.log("sub-add: \(url.path)")
        mpv.command("sub-add", [url.path, "select"])
    }

    // MARK: - Recording

    /// Starts recording the current stream into the configured recording
    /// folder with an auto-generated name (mpv `stream-record`).
    ///
    /// MPVKit's FFmpeg has no encoders, so recording is a stream copy — the
    /// .mkv container accepts virtually every codec combination. A few
    /// seconds in, the output is checked; if nothing was written the
    /// recording failed and the user is told.
    func startRecording() {
        guard !isIdle, !isRecording else { return }
        let directory = AppSettings.shared.recordingDirectory
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let path = directory + "/BrushLLMPlayer-recording-" + formatter.string(from: Date()) + ".mkv"
        mpv.setString("stream-record", path)
        isRecording = true
        DebugLog.log("recording started: \(path)")

        // Verify the recording actually produces data.
        let checkPath = path
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isRecording else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: checkPath)[.size] as? Int64) ?? 0
            if size == 0 {
                self.stopRecording()
                self.loadErrorMessage = L("player.record-failed", "Recording failed: this stream cannot be stream-copied")
                DebugLog.log("recording produced no data — stopped")
            }
        }
    }

    func stopRecording() {
        mpv.setString("stream-record", "no")
        isRecording = false
        DebugLog.log("recording stopped")
    }

    // MARK: - Bookmarks

    /// Bookmarks a named position in the current file.
    func addBookmark() {
        guard !isIdle, let path = currentPath else { return }
        PlaybackStore.shared.addBookmark(path: path, title: mediaTitle.isEmpty ? fileName : mediaTitle,
                                         time: position)
        currentFileBookmarks = PlaybackStore.shared.bookmarks(for: path)
        DebugLog.log("bookmark added at \(position)")
    }

    func bookmarksForCurrentFile() -> [Bookmark] {
        guard let path = currentPath else { return [] }
        return PlaybackStore.shared.bookmarks(for: path)
    }

    // MARK: - Mini window (PiP-lite) & fullscreen

    /// The windowed (non-fullscreen, non-mini) frame to restore.
    private var lastWindowedFrame: NSRect?

    /// Mini window: floating level + compact control bar + a shrunk frame.
    /// NOTE: the floating level must be dropped before any fullscreen
    /// transition — AppKit refuses fullscreen for non-normal levels.
    /// All frame changes run async — a synchronous setFrame gets overridden
    /// by SwiftUI's window layout pass, which is what made the transitions
    /// eat clicks and stutter before.
    func toggleMiniWindow() {
        guard let window = playerWindow() else { return }
        if isMiniWindow {
            // Exit mini: restore on the next runloop tick — after SwiftUI's
            // layout pass for the state flip, but without a visible delay.
            isMiniWindow = false
            let restore = lastWindowedFrame
                ?? NSRect(x: window.frame.origin.x, y: window.frame.origin.y,
                          width: 900, height: 500)
            DispatchQueue.main.async {
                window.setFrame(restore, display: true, animate: true)
            }
        } else {
            isMiniWindow = true
            if window.styleMask.contains(.fullScreen) {
                // Leave fullscreen first; shrink once its transition settles.
                window.toggleFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.shrinkToMini()
                }
            } else {
                lastWindowedFrame = window.frame
                // Next runloop tick: SwiftUI's layout for the state flip
                // lands within the same frame, so the shrink starts
                // immediately — no visible dead time.
                DispatchQueue.main.async { [weak self] in
                    self?.shrinkToMini()
                }
            }
        }
    }

    private func shrinkToMini() {
        guard isMiniWindow, let window = playerWindow(),
              !window.styleMask.contains(.fullScreen) else { return }
        let aspect = windowAspect > 0 ? windowAspect : 16.0 / 9.0
        let width: CGFloat = 420
        let height = max(width / aspect, 180) + 44
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true, animate: true)
    }

    /// Fullscreen toggle that drops mini mode first — the two states are
    /// mutually exclusive. Fullscreen engages from ANY window size, so no
    /// frame restore is needed here (one click, no stutter).
    func toggleFullscreen() {
        guard let window = playerWindow() else {
            DebugLog.log("toggleFullscreen: NO WINDOW FOUND")
            return
        }
        if !window.styleMask.contains(.fullScreen) && isMiniWindow {
            // A floating-level window cannot enter fullscreen, and changing
            // the level and starting the transition in the same runloop tick
            // cancels the transition — reset the level now, toggle on the
            // next tick. The didEnterFullScreen observer clears the state.
            window.level = .normal
            // The level change needs time to propagate through the window
            // server; toggling fullscreen on the very next tick still sees
            // a floating window and refuses.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                window.toggleFullScreen(nil)
            }
            return
        }
        window.toggleFullScreen(nil)
    }

    /// Tracks the windowed frame (saved before entering fullscreen and after
    /// leaving it) and clears mini state when fullscreen is entered by other
    /// paths (menu, double-click, system gestures).
    private func observeWindowNotifications() {
        let nameFilter: (Notification) -> Bool = { note in
            (note.object as? NSWindow)?.title == "BrushLLM Player"
        }
        NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)
            .filter(nameFilter)
            .sink { [weak self] note in
                // Enter the geometry-animating state for the whole transition
                // (snapshot + async GL drawing).
                if let window = note.object as? NSWindow {
                    self?.liveResizeWidth = window.frame.width
                }
                self?.fullscreenAnimating = true
                self?.refreshResizingState()
                // Only remember genuinely windowed (non-mini) frames —
                // restoring a mini frame on exit would loop.
                if let window = note.object as? NSWindow, self?.isMiniWindow != true {
                    self?.lastWindowedFrame = window.frame
                }
            }
            .store(in: &cancellables)
        // Mini state clears only AFTER the transition completes — flipping it
        // during willEnterFullScreen cancels the transition itself.
        NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
            .filter(nameFilter)
            .sink { [weak self] _ in
                self?.isMiniWindow = false
                self?.fullscreenAnimating = false
                self?.refreshResizingState()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)
            .filter(nameFilter)
            .sink { [weak self] _ in
                self?.fullscreenAnimating = true
                self?.refreshResizingState()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
            .filter(nameFilter)
            .sink { [weak self] note in
                self?.fullscreenAnimating = false
                self?.refreshResizingState()
                if let window = note.object as? NSWindow {
                    self?.lastWindowedFrame = window.frame
                }
            }
            .store(in: &cancellables)
    }

    private func playerWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "BrushLLM Player" }
    }

    // MARK: - Titlebar tint

    /// Brand purple used for the window titlebar's "BrushLLM Player" title.
    private static let brandTitleColor = NSColor(red: 0x89/255, green: 0x3C/255, blue: 0xED/255, alpha: 1)
    private static var titleTreeDumped = false
    private var titleWatchdog: Timer?

    /// Tints the window titlebar's "BrushLLM Player" title with the brand
    /// purple. The standard title label has no public coloring API, so the
    /// titlebar view tree is traversed for the text field. Runs slightly
    /// delayed — the titlebar hierarchy materializes after the window is
    /// on screen.
    ///
    /// The tint is not one-shot: the system re-styles the title label when
    /// the SwiftUI scene re-applies the window title or the titlebar
    /// relayouts (fullscreen transitions, appearance switches) — and a
    /// re-applied identical title emits no `didChangeTitle` notification,
    /// so there is no reliable event to hook. A 1-second watchdog re-checks
    /// the color instead; the tree walk covers ~a dozen views.
    func applyBrandTitle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let window = self.playerWindow() else { return }
            Self.tintTitle(in: window)
            self.startTitleWatchdog()
        }
    }

    private func startTitleWatchdog() {
        guard titleWatchdog == nil else { return }
        titleWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let window = self.playerWindow() else { return }
            Self.tintTitle(in: window)
        }
    }

    private static func isBrandColor(_ color: NSColor?) -> Bool {
        guard let color, let rgb = color.usingColorSpace(.deviceRGB) else { return false }
        return abs(rgb.redComponent - 0x89/255) < 0.01
            && abs(rgb.greenComponent - 0x3C/255) < 0.01
            && abs(rgb.blueComponent - 0xED/255) < 0.01
    }

    private static func tintTitle(in window: NSWindow) {
        // The traffic lights' superview is the titlebar container that also
        // hosts the title label.
        guard let anchor = window.standardWindowButton(.closeButton)?.superview else { return }
        var found = false
        func search(_ view: NSView, depth: Int) {
            if depth > 6 { return }
            if let field = view as? NSTextField,
               field.stringValue == window.title, !field.isEditable {
                if !isBrandColor(field.textColor) {
                    field.textColor = brandTitleColor
                    DebugLog.log("titlebar: re-tinted title (system had reset the color)")
                }
                found = true
            }
            for sub in view.subviews { search(sub, depth: depth + 1) }
        }
        search(anchor, depth: 0)
        if !found && !titleTreeDumped {
            // Fallback: dump the tree once so the structure can be adapted.
            titleTreeDumped = true
            DebugLog.log("titlebar: title field not found; tree:")
            func dump(_ view: NSView, depth: Int) {
                if depth > 5 { return }
                DebugLog.log("  \(String(repeating: " ", count: depth))\(type(of: view)) '\(view.identifier?.rawValue ?? "-")'")
                for sub in view.subviews { dump(sub, depth: depth + 1) }
            }
            dump(anchor, depth: 0)
        }
    }

    private func applyWindowLevel() {
        let level: NSWindow.Level = (isOnTop || isMiniWindow) ? .floating : .normal
        for window in NSApp.windows where window.title == "BrushLLM Player" {
            // Changing the level mid-fullscreen-transition cancels it.
            guard !window.styleMask.contains(.fullScreen) else { continue }
            window.level = level
        }
    }

    // MARK: - Thumbnails

    /// Generates a thumbnail at the exact hovered position (on demand).
    /// For EDL playback, maps the position to the correct VOB file.
    func thumbnail(at position: Double) -> NSImage? {
        // Return the cached image if it's for the same position (±0.5s)
        if let cached = hoverThumbnail,
           abs(cachedPosition - position) < 1.0 {
            return cached
        }
        // Trigger async generation; the preview updates when ready
        generateHoverThumbnail(at: position)
        // Return the previous image while the new one generates (no flicker)
        return hoverThumbnail
    }

    private var cachedPosition: Double = -1
    /// The latest hover position requested (generation adopts only this).
    /// Protected by hoverLock to prevent data races between main and
    /// background threads.
    private var latestHoverPosition: Double = -1
    private let hoverLock = NSLock()
    /// Prevents concurrent generations (one at a time).
    private var isGenerating = false

    /// Thread-safe read/write for latestHoverPosition.
    private var safeLatestPosition: Double {
        get {
            hoverLock.lock()
            defer { hoverLock.unlock() }
            return latestHoverPosition
        }
        set {
            hoverLock.lock()
            defer { hoverLock.unlock() }
            latestHoverPosition = newValue
        }
    }

    private func generateHoverThumbnail(at position: Double) {
        safeLatestPosition = position

        // Only one generation at a time; the next hover triggers after.
        guard !isGenerating else { return }
        isGenerating = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            // Limit iterations to prevent infinite loops if the mouse
            // never stops moving.
            var iterations = 0
            while let self, iterations < 10 {
                iterations += 1
                let target = self.safeLatestPosition
                let image = self.thumbnailMPV.captureFrame(at: target)

                // Adopt the result on the main thread (async to avoid
                // deadlock if main is waiting on this queue).
                let isLatest = self.safeLatestPosition
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if abs(self.safeLatestPosition - target) < 0.5 {
                        self.hoverThumbnail = image
                        self.cachedPosition = target
                    }
                }

                // If no newer position is pending, stop.
                if abs(isLatest - target) < 0.5 { break }
            }
            DispatchQueue.main.async { [weak self] in
                self?.isGenerating = false
            }
        }
    }

    private func loadThumbnails(for path: String) {
        // Load the file into the headless thumbnail instance so it's ready
        // to seek and capture frames on hover.
        hoverThumbnail = nil
        cachedPosition = -1
        let filePath = path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.thumbnailMPV.loadFile(filePath)
        }
    }

    /// Lazy 302 resolution for playlist entries. Entries are enqueued with
    /// their original WebDAV URL (credentials embedded) because signed CDN
    /// URLs expire within minutes — resolving at enqueue time would 403 by
    /// the time mpv reaches the entry. When mpv STARTS an entry, this
    /// resolves the redirect once and replaces the entry in place, so
    /// pause/seek re-opens the final address instead of re-redirecting.
    private var resolvedPlaylistURLs: Set<String> = []

    private func resolvePendingWebDAVEntry() {
        let playlist = mpv.playlist
        let index = mpv.getInt("playlist-pos") ?? -1
        guard index >= 0, index < playlist.count else { return }
        let rawPath = playlist[index].filename

        // Only WebDAV URLs with embedded credentials need resolution; local
        // paths, plain http and already-resolved URLs pass through.
        guard rawPath.contains("://"), rawPath.contains("@"),
              let url = URL(string: rawPath) else { return }
        guard !resolvedPlaylistURLs.contains(rawPath) else { return }
        resolvedPlaylistURLs.insert(rawPath)

        // Find the source whose origin this URL belongs to.
        let sources = MediaServerStore.shared.sources.filter { $0.kind == .webdav }
        guard let source = sources.first(where: { src in
            WebDAVClient.origin(of: src).map { rawPath.hasPrefix($0) } ?? false
        }) else { return }
        let password = MediaServerStore.shared.password(for: source)

        Task { @MainActor in
            let resolved = await WebDAVClient.resolvePlaybackURL(
                url, source: source, password: password,
                userAgent: AppSettings.shared.userAgent)
            // Only replace when a redirect actually resolved to something new.
            if resolved.absoluteString != rawPath {
                mpv.command("loadfile", [resolved.absoluteString, "replace"])
                DebugLog.log("playlist 302: entry \(index) resolved")
            }
        }
    }

    // MARK: - History

    private func startHistoryUpdates() {
        historyTimer?.invalidate()
        historyTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.isIdle, let path = self.currentPath else { return }
            PlaybackStore.shared.updatePosition(path: path, position: self.position)
        }
    }

    private func startBufferingTimer() {
        bufferingTimer?.invalidate()
        bufferingSeconds = 0
        bufferingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.bufferingSeconds += 1
        }
    }

    private func stopBufferingTimer() {
        bufferingTimer?.invalidate()
        bufferingTimer = nil
        bufferingSeconds = 0
    }

    private func stopHistoryUpdates() {
        historyTimer?.invalidate()
        historyTimer = nil
        if let path = currentPath, !isIdle {
            PlaybackStore.shared.updatePosition(path: path, position: position)
        }
    }

    private func applyLoopMode() {
        switch loopMode {
        case .off:
            mpv.setString("loop-file", "no")
            mpv.setString("loop-playlist", "no")
        case .file:
            mpv.setString("loop-file", "inf")
            mpv.setString("loop-playlist", "no")
        case .playlist:
            mpv.setString("loop-file", "no")
            mpv.setString("loop-playlist", "inf")
        }
    }

    // MARK: - Aspect

    /// How the video is fitted into the window.
    enum AspectMode: String, CaseIterable, Identifiable {
        case fit       // letterbox, keep video aspect (default)
        case fill      // crop-fill the window, tracks window aspect
        case stretch   // distort to the window
        case custom    // fixed ratio override (4:3, 16:9, …)

        var id: String { rawValue }
    }

    private func applyAspectMode() {
        switch aspectMode {
        case .fit:
            mpv.setString("video-aspect-override", "no")
            mpv.setFlag("keepaspect", true)
        case .fill:
            mpv.setString("video-aspect-override", String(format: "%.5f", Double(windowAspect)))
            mpv.setFlag("keepaspect", true)
        case .stretch:
            mpv.setString("video-aspect-override", "no")
            mpv.setFlag("keepaspect", false)
        case .custom:
            mpv.setString("video-aspect-override", aspectOverride ?? "no")
            mpv.setFlag("keepaspect", true)
        }
    }

    // MARK: - Crop & rotation

    /// How the video is cropped.
    enum CropMode: String, CaseIterable, Identifiable {
        case off      // no crop
        case ratio    // crop to a fixed ratio, centered (4:3, 16:9, …)
        case custom   // manual margins from each edge (percent)

        var id: String { rawValue }
    }

    /// Crop mode; `ratio` and `custom` compute a pixel rect from the source size.
    @Published var cropMode: CropMode = .off {
        didSet { applyCrop() }
    }
    /// Target ratio for ratio-based crop ("4:3", "16:9", "2.35:1", "1:1").
    @Published var cropRatio: String = "16:9" {
        didSet { applyCrop() }
    }
    /// Custom crop margins, percent of the source width/height (0–45 each).
    @Published var cropTop: Double = 0 { didSet { applyCrop() } }
    @Published var cropBottom: Double = 0 { didSet { applyCrop() } }
    @Published var cropLeft: Double = 0 { didSet { applyCrop() } }
    @Published var cropRight: Double = 0 { didSet { applyCrop() } }

    /// Clockwise rotation in degrees; mpv accepts multiples of 90.
    @Published var videoRotation: Int = 0 {
        didSet { applyRotation() }
    }

    /// Source video dimensions (from `video-params`); crop rects are computed
    /// against these, so the crop is reapplied whenever a new file's size lands.
    private var videoSourceSize: (w: Int, h: Int) = (0, 0)

    /// True when any crop is active (drives the control bar button's lit state).
    var isCropActive: Bool { cropMode != .off }

    func setCropRatio(_ ratio: String) {
        cropRatio = ratio
        cropMode = .ratio
    }

    func resetCrop() {
        cropMode = .off
        cropRatio = "16:9"
        cropTop = 0; cropBottom = 0; cropLeft = 0; cropRight = 0
    }

    func rotate(by degrees: Int) {
        videoRotation = ((videoRotation + degrees) % 360 + 360) % 360
    }

    /// Applies the crop to mpv as a "wxh+x+y" rect; an empty string clears it.
    private func applyCrop() {
        let (w, h) = videoSourceSize
        guard w > 0, h > 0, cropMode != .off else {
            mpv.setString("video-crop", "")
            return
        }
        switch cropMode {
        case .off:
            mpv.setString("video-crop", "")
        case .ratio:
            guard let target = parseRatio(cropRatio) else { return }
            let source = Double(w) / Double(h)
            var cw = w, ch = h
            if source > target {
                cw = Int(Double(h) * target)
            } else {
                ch = Int(Double(w) / target)
            }
            let x = (w - cw) / 2
            let y = (h - ch) / 2
            setCropRect("\(cw)x\(ch)+\(x)+\(y)")
        case .custom:
            let x = Int(Double(w) * cropLeft / 100.0)
            let y = Int(Double(h) * cropTop / 100.0)
            let cw = max(w - x - Int(Double(w) * cropRight / 100.0), 16)
            let ch = max(h - y - Int(Double(h) * cropBottom / 100.0), 16)
            setCropRect("\(cw)x\(ch)+\(x)+\(y)")
        }
    }

    private func setCropRect(_ rect: String) {
        mpv.setString("video-crop", rect)
        DebugLog.log("crop: \(rect) (source \(videoSourceSize.w)x\(videoSourceSize.h))")
    }

    private func parseRatio(_ ratio: String) -> Double? {
        let parts = ratio.split(separator: ":")
        guard parts.count == 2,
              let a = Double(parts[0]), let b = Double(parts[1]), b != 0 else { return nil }
        return a / b
    }

    private func applyRotation() {
        mpv.setInt("video-rotate", videoRotation)
        DebugLog.log("rotation: \(videoRotation)°")
    }

    // MARK: - Event handling (main thread)

    private func handleEvent(_ event: MPVEvent) {
        switch event {
        case .propertyChange(let name, let value):
            handlePropertyChange(name, value)

        case .startFile:
            isBuffering = true
            loadErrorMessage = nil
            startBufferingTimer()
            resolvePendingWebDAVEntry()

        case .fileLoaded:
            isBuffering = false
            stopBufferingTimer()
            isIdle = false
            // Snapshot state that only makes sense once a file is loaded.
            duration = mpv.getDouble("duration") ?? 0
            hwdecCurrent = nonEmpty(mpv.getString("hwdec-current"))
            mediaTitle = mpv.getString("media-title") ?? ""
            fileName = mpv.getString("filename") ?? ""
            currentPath = mpv.getString("path") ?? fileName
            // mpv's EDL duration estimate is unreliable for VOB files
            // (variable bitrate MPEG-2); probe the real total from the VOBs.
            if let vobPaths = discVobPaths, fileName.hasSuffix(".edl") {
                DebugLog.log("ISO (DVD): probing \(vobPaths.count) VOBs for real duration")
                probeDiscDuration(vobPaths)
            } else if discVobPaths != nil {
                DebugLog.log("ISO (DVD): probe skipped, fileName=\(fileName)")
            }
            refreshTracks()
            refreshPlaylist()
            refreshChapters()
            PlaybackStore.shared.recordPlay(path: currentPath ?? fileName,
                                            title: mediaTitle.isEmpty ? fileName : mediaTitle,
                                            duration: duration)
            startHistoryUpdates()
            if let path = currentPath {
                loadThumbnails(for: path)
                currentFileBookmarks = PlaybackStore.shared.bookmarks(for: path)
            }
            DebugLog.log("fileLoaded: \(fileName), duration=\(duration), hwdec=\(hwdecCurrent ?? "nil"), audio=\(audioTracks.count), sub=\(subtitleTracks.count), playlist=\(playlist.count)")

        case .endFile(let reason, let errorCode):
            isBuffering = false
            stopBufferingTimer()
            if reason == MPV_END_FILE_REASON_ERROR {
                let message = String(cString: mpv_error_string(errorCode))
                loadErrorMessage = message
            }

        case .logMessage:
            break

        case .shutdown:
            isIdle = true
            isPaused = true
        }
    }

    private func handlePropertyChange(_ name: String, _ value: MPVPropertyValue?) {
        // Suppress didSet write-backs: these values came FROM mpv.
        isApplyingFromMPV = true
        defer { isApplyingFromMPV = false }
        switch name {
        case "pause":
            if case .flag(let paused)? = value { isPaused = paused }
        case "time-pos":
            if case .double(let pos)? = value, !isScrubbing { position = max(pos, 0) }
        case "duration":
            if case .double(let dur)? = value { duration = max(dur, 0) }
        case "mute":
            if case .flag(let muted)? = value { isMuted = muted }
        case "speed":
            if case .double(let newSpeed)? = value { speed = newSpeed }
        case "eof-reached":
            if case .flag(let eof)? = value, eof { isPaused = true }
        case "idle-active":
            if case .flag(let idle)? = value {
                isIdle = idle
                if idle {
                    stopHistoryUpdates()
                    position = 0
                    duration = 0
                    mediaTitle = ""
                    fileName = ""
                    hwdecCurrent = nil
                    hoverThumbnail = nil
                    currentFileBookmarks = []
                    discVobPaths = nil
                    thumbnailMPV.shutdown()
                }
            }
        case "filename":
            if case .string(let name)? = value { fileName = name }
        case "media-title":
            if case .string(let title)? = value { mediaTitle = title }
        case "hwdec-current":
            if case .string(let hwdec)? = value { hwdecCurrent = nonEmpty(hwdec) }
        case "track-list":
            refreshTracks()
        case "playlist":
            refreshPlaylist()
        case "chapter-list":
            refreshChapters()
        case "video-params":
            // Source dimensions (before aspect correction); recompute the crop
            // rect so a persistent crop setting follows each new file.
            // mpv re-fires this property dozens of times per second even when
            // the dimensions are unchanged — skip the redundant work (the
            // per-line file log alone was measurable during playback).
            if let params = mpv.getNode("video-params") as? [String: Any],
               let w = params["w"] as? Int, let h = params["h"] as? Int, w > 0, h > 0 {
                guard videoSourceSize != (w, h) else { break }
                videoSourceSize = (w, h)
                DebugLog.log("video-params: \(w)x\(h)")
                applyCrop()
            } else if videoSourceSize != (0, 0) {
                videoSourceSize = (0, 0)
            }
        case "chapter":
            if case .int(let chapter)? = value {
                currentChapter = chapter >= 0 ? chapter : nil
            } else if case .double(let chapter)? = value {
                currentChapter = Int(chapter) >= 0 ? Int(chapter) : nil
            }
        case "ab-loop-a":
            if case .double(let a)? = value { abLoopA = a } else { abLoopA = nil }
        case "ab-loop-b":
            if case .double(let b)? = value { abLoopB = b } else { abLoopB = nil }
        case "audio-delay":
            if case .double(let delay)? = value {
                audioDelay = delay
                videoDelay = -delay
            }
        default:
            break
        }
    }

    // MARK: - Data refresh

    private func refreshTracks() {
        let tracks = mpv.trackList
        let audio = tracks.filter { $0.kind == .audio }
        let subs = tracks.filter { $0.kind == .sub }
        let video = tracks.filter { $0.kind == .video }
        let audioId = audio.first(where: \.isSelected)?.id
        let subId = subs.first(where: \.isSelected)?.id
        // mpv re-fires track-list events with identical content; assigning
        // equal values to @Published still notifies observers, so skip.
        guard audio != audioTracks || subs != subtitleTracks || video != videoTracks
                || audioId != currentAudioTrack || subId != currentSubtitleTrack else { return }
        audioTracks = audio
        subtitleTracks = subs
        videoTracks = video
        currentAudioTrack = audioId
        currentSubtitleTrack = subId
        DebugLog.log("refreshTracks: total=\(tracks.count), audio=\(audio.count), sub=\(subs.count)")
    }

    private func refreshPlaylist() {
        playlist = mpv.playlist
        currentPlaylistIndex = playlist.firstIndex(where: \.isCurrent)
    }

    private func refreshChapters() {
        let list = mpv.chapterList
        let chapter = (mpv.getInt("chapter") ?? -1) >= 0 ? mpv.getInt("chapter")! : nil
        guard list != chapters || chapter != currentChapter else { return }
        chapters = list
        currentChapter = chapter
        DebugLog.log("refreshChapters: count=\(list.count), current=\(chapter.map(String.init) ?? "nil")")
    }

    private func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty, string != "no" else { return nil }
        return string
    }
}
