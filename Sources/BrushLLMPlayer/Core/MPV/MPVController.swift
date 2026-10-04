import Foundation
import OpenGL.GL
import Libmpv

/// Events surfaced to the app layer. All events are delivered on the main thread.
enum MPVEvent {
    case propertyChange(name: String, value: MPVPropertyValue?)
    case startFile
    case fileLoaded
    case endFile(reason: mpv_end_file_reason, errorCode: Int32)
    case logMessage(prefix: String, level: String, text: String)
    case shutdown
}

enum MPVPropertyValue {
    case flag(Bool)
    case int(Int)
    case double(Double)
    case string(String)
}

/// Thin, thread-safe wrapper around the libmpv client API.
///
/// Thread discipline (mirrors IINA's MPVController):
/// - The client API (commands, properties) is thread-safe and callable from anywhere.
/// - Events are drained on a dedicated serial queue driven by the wakeup callback.
///   That queue does nothing but call `mpv_wait_event` and dispatch to the main
///   thread, because mpv's event ring buffer is finite and slow handling drops events.
/// - The render context is created while the video layer's CGL context is current,
///   and is used for rendering only from the layer's draw path.
final class MPVController {
    private(set) var mpv: OpaquePointer?
    private(set) var renderContext: OpaquePointer?

    /// Serial queue that only drains mpv events.
    private let eventQueue = DispatchQueue(label: "dev.brushllm.player.mpv.events", qos: .userInteractive)

    /// Serializes render-context lifecycle against the GL draw path: the context
    /// is (re)created on the main thread while draws run on the GL queue.
    private let renderLock = NSLock()

    /// Receives every event on the main thread.
    var eventHandler: ((MPVEvent) -> Void)?

    /// Properties the UI is driven by. Observation happens before `mpv_initialize`.
    private static let observedProperties: [(name: String, format: mpv_format)] = [
        ("pause", MPV_FORMAT_FLAG),
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("volume", MPV_FORMAT_DOUBLE),
        ("mute", MPV_FORMAT_FLAG),
        ("speed", MPV_FORMAT_DOUBLE),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("idle-active", MPV_FORMAT_FLAG),
        ("filename", MPV_FORMAT_STRING),
        ("media-title", MPV_FORMAT_STRING),
        ("hwdec-current", MPV_FORMAT_STRING),
        ("chapter", MPV_FORMAT_INT64),
        ("ab-loop-a", MPV_FORMAT_DOUBLE),
        ("ab-loop-b", MPV_FORMAT_DOUBLE),
        ("audio-delay", MPV_FORMAT_DOUBLE),
        // Track/chapter/playlist data is re-read on demand; observe for change signals.
        ("track-list", MPV_FORMAT_NONE),
        ("chapter-list", MPV_FORMAT_NONE),
        ("playlist", MPV_FORMAT_NONE),
        // Source video dimensions: crop rects are computed against these.
        ("video-params", MPV_FORMAT_NONE),
    ]

    // MARK: - Lifecycle

    init() {
        mpv = mpv_create()
        precondition(mpv != nil, "BrushLLMPlayer: mpv_create() failed")
    }

    /// Applies options, registers the wakeup callback and observers, then
    /// initializes the mpv core. Must be called exactly once, before any playback.
    func start(hardwareDecoding: Bool = true) {
        guard let mpv else { return }

        // Embedded-player defaults: never read user config files, never load Lua
        // scripts or the built-in OSC — the app owns all UI.
        setOption("config", "no")
        setOption("osc", "no")
        setOption("load-scripts", "no")
        setOption("terminal", "no")
        setOption("msg-level", "all=warn")
        // The app manages external subtitles explicitly (sub-add); mpv's own
        // directory scan for matching sidecar files can stall on large or
        // cloud-synced folders (e.g. Downloads) — off unless the user opts in.
        setOption("sub-auto", AppSettings.shared.autoLoadSubtitles ? "exact" : "no")
        setOption("audio-file-auto", "no")
        setOption("cover-art-auto", "no")
        setOption("vo", "libmpv")
        setOption("hwdec", hardwareDecoding ? "auto-safe" : "no")
        // Direct rendering (decoder writes straight into VO buffers) runs a
        // buffer-allocation callback through mpv's dispatch — which deadlocks
        // against main-thread mpv_get_property calls from the property-change
        // handler while the decoder starts (main waits for the core, the core
        // waits for the decoder, the decoder waits for the dispatch). The
        // extra frame copy in software decoding is the safe trade.
        setOption("vd-lavc-dr", "no")
        setOption("keepaspect", "yes")
        setOption("title", "BrushLLM Player")
        // Network streaming: mpv's demuxer runs network I/O on its own threads;
        // a readahead buffer keeps HLS/https playback smooth.
        setOption("cache", "yes")
        setOption("demuxer-readahead-secs", String(Int(AppSettings.shared.readaheadSeconds)))
        setOption("demuxer-max-bytes", "\(Int(AppSettings.shared.bufferMB))MiB")
        setOption("network-timeout", "15")
        // Remote file streams (WebDAV/FTP/Emby over http) don't always
        // advertise Range support, and mpv then refuses every seek with
        // "Cannot seek in this stream" — scrubbing the progress bar killed
        // playback. Forcing seekable lets mpv re-open the URL at the seek
        // target (a range request); harmless for local files.
        setOption("force-seekable", "yes")
        // User-Agent from settings (browser UA by default: many CDNs reject
        // the default "libmpv"/"Lavf" agents outright).
        setOption("user-agent", AppSettings.shared.userAgent)
        // Resume playback where the user left off (mpv watch-later files).
        // config=no means mpv has no default state directory — set one explicitly.
        setOption("save-position-on-quit", "yes")
        let appSupport = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
                          ?? NSTemporaryDirectory()) + "/BrushLLM Player"
        let watchLaterDir = appSupport + "/watch_later"
        try? FileManager.default.createDirectory(atPath: watchLaterDir, withIntermediateDirectories: true)
        setOption("watch-later-directory", watchLaterDir)
        // Screenshots are taken from the GL framebuffer by PlayerCore and
        // saved to the user-configured folder — no mpv screenshot options
        // (they would create a second, differently-named directory).

        #if DEBUG
        mpv_request_log_messages(mpv, "warn")
        #else
        mpv_request_log_messages(mpv, "no")
        #endif

        // The wakeup callback runs on an mpv-internal thread and must not call
        // back into mpv; it only signals the event queue.
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let controller = Unmanaged<MPVController>.fromOpaque(ctx).takeUnretainedValue()
            controller.readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())

        for observer in Self.observedProperties {
            mpv_observe_property(mpv, 0, observer.name, observer.format)
        }

        chk(mpv_initialize(mpv), "mpv_initialize")
    }

    /// Tears down the render context first (required before destroying the core),
    /// then the core itself. Blocks until the core has fully shut down.
    func shutdown() {
        guard let mpv else { return }
        uninitRendering()
        mpv_terminate_destroy(mpv)
        self.mpv = nil
    }

    // MARK: - Rendering

    /// Creates the OpenGL render context. Must be called while the video layer's
    /// CGL context is current on the calling thread; every later render call must
    /// use that same context (guaranteed by `VideoLayer.copyCGLContext`).
    ///
    /// When the video view is recreated (window closed and reopened), the new
    /// layer owns a different CGL context, so any previous render context is torn
    /// down and rebuilt against the new one.
    func initRendering(layer: VideoLayer) {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let mpv else { return }
        if renderContext != nil {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            renderContext = nil
        }
        let apiType = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var glInitParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                MPVController.getOpenGLProcAddress(name)
            },
            get_proc_address_ctx: nil
        )
        withUnsafeMutablePointer(to: &glInitParams) { glInitParams in
            var advanced: CInt = 1
            withUnsafeMutablePointer(to: &advanced) { advanced in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: glInitParams),
                    mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advanced),
                    mpv_render_param(),
                ]
                chk(mpv_render_context_create(&renderContext, mpv, &params), "mpv_render_context_create")
            }
        }
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(
            renderContext,
            { ctx in
                guard let ctx else { return }
                let layer = Unmanaged<VideoLayer>.fromOpaque(ctx).takeUnretainedValue()
                layer.renderUpdate()
            },
            Unmanaged.passUnretained(layer).toOpaque()
        )
    }

    func uninitRendering() {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
    }

    /// Whether mpv has a new frame ready; consumes the update flags.
    func shouldRenderUpdateFrame() -> Bool {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let renderContext else { return false }
        let flags: UInt64 = mpv_render_context_update(renderContext)
        return flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) > 0
    }

    /// Renders into the currently bound OpenGL framebuffer. Must be called with the
    /// layer's CGL context current.
    func render(fbo: GLint, width: Int32, height: Int32, depth: GLint) {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let renderContext else { return }
        var fboData = mpv_opengl_fbo(fbo: fbo, w: width, h: height, internal_format: 0)
        var flip: CInt = 1
        var depth = depth
        withUnsafeMutablePointer(to: &fboData) { fboData in
            withUnsafeMutablePointer(to: &flip) { flip in
                withUnsafeMutablePointer(to: &depth) { depth in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboData),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flip),
                        mpv_render_param(type: MPV_RENDER_PARAM_DEPTH, data: depth),
                        mpv_render_param(),
                    ]
                    mpv_render_context_render(renderContext, &params)
                }
            }
        }
    }

    // MARK: - Commands

    /// Sends a command by name with string arguments, e.g. `command("loadfile", [path, "replace"])`.
    func command(_ name: String, _ args: [String] = []) {
        guard let mpv else { return }
        let strArgs = [name] + args
        var cargs: [UnsafePointer<CChar>?] = strArgs.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer {
            for case let ptr? in cargs {
                free(UnsafeMutablePointer(mutating: ptr))
            }
        }
        chk(mpv_command(mpv, &cargs), "command \(name)")
    }

    // MARK: - Properties

    func setFlag(_ name: String, _ value: Bool) {
        guard let mpv else { return }
        var data: Int32 = value ? 1 : 0
        chk(mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data), "set \(name)")
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var data = value
        chk(mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data), "set \(name)")
    }

    func setInt(_ name: String, _ value: Int) {
        guard let mpv else { return }
        var data = Int64(value)
        chk(mpv_set_property(mpv, name, MPV_FORMAT_INT64, &data), "set \(name)")
    }

    func getInt(_ name: String) -> Int? {
        guard let mpv else { return nil }
        var data: Int64 = 0
        guard mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data) >= 0 else { return nil }
        return Int(data)
    }

    func setString(_ name: String, _ value: String) {
        guard let mpv else { return }
        chk(mpv_set_property_string(mpv, name, value), "set \(name)")
    }

    func getFlag(_ name: String) -> Bool? {
        guard let mpv else { return nil }
        var data: Int32 = 0
        guard mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data) >= 0 else { return nil }
        return data != 0
    }

    func getDouble(_ name: String) -> Double? {
        guard let mpv else { return nil }
        var data = 0.0
        guard mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data) >= 0 else { return nil }
        return data
    }

    func getString(_ name: String) -> String? {
        guard let mpv else { return nil }
        guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    /// Reads a property as a parsed node tree (arrays/maps of values).
    func getNode(_ name: String) -> Any? {
        MPVNodeParser.getProperty(self, name)
    }

    /// The current `track-list` as typed models.
    var trackList: [TrackInfo] {
        guard let raw = getNode("track-list") as? [[String: Any]] else { return [] }
        return raw.compactMap { TrackInfo.from(mpvMap: $0) }
    }

    /// The current `playlist` as typed models.
    var playlist: [PlaylistItem] {
        guard let raw = getNode("playlist") as? [[String: Any]] else { return [] }
        return raw.compactMap { PlaylistItem.from(mpvMap: $0) }
    }

    /// The current `chapter-list` as typed models.
    var chapterList: [ChapterInfo] {
        guard let raw = getNode("chapter-list") as? [[String: Any]] else { return [] }
        return raw.enumerated().compactMap { ChapterInfo.from(mpvMap: $1, index: $0) }
    }

    // MARK: - Options (before initialize)

    private func setOption(_ name: String, _ value: String) {
        guard let mpv else { return }
        chk(mpv_set_option_string(mpv, name, value), "option \(name)=\(value)")
    }

    // MARK: - Event loop

    private func readEvents() {
        eventQueue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            while true {
                let event = mpv_wait_event(mpv, 0)
                guard let event else { break }
                let eventId = event.pointee.event_id
                if eventId == MPV_EVENT_NONE { break }
                self.handleEvent(event)
                // The event pointer is only valid until the next mpv_wait_event call,
                // so everything needed is copied out inside handleEvent.
                if eventId == MPV_EVENT_SHUTDOWN { break }
            }
        }
    }

    private func handleEvent(_ event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.pointee.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            let value = Self.parsePropertyValue(property)
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler?(.propertyChange(name: name, value: value))
            }

        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.pointee.data else { return }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let prefix = String(cString: message.prefix)
            let level = String(cString: message.level)
            let text = String(cString: message.text).trimmingCharacters(in: .whitespacesAndNewlines)
            DebugLog.log("[\(prefix)] \(level): \(text)")

        case MPV_EVENT_START_FILE:
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler?(.startFile)
            }

        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler?(.fileLoaded)
            }

        case MPV_EVENT_END_FILE:
            guard let data = event.pointee.data else { return }
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            let reason = endFile.reason
            let errorCode = endFile.error
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler?(.endFile(reason: reason, errorCode: errorCode))
            }

        case MPV_EVENT_SHUTDOWN:
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler?(.shutdown)
            }

        default:
            break
        }
    }

    private static func parsePropertyValue(_ property: mpv_event_property) -> MPVPropertyValue? {
        guard let data = property.data else { return nil }
        switch property.format {
        case MPV_FORMAT_FLAG:
            let flag = data.assumingMemoryBound(to: Int32.self).pointee
            return .flag(flag != 0)
        case MPV_FORMAT_INT64:
            return .int(Int(data.assumingMemoryBound(to: Int64.self).pointee))
        case MPV_FORMAT_DOUBLE:
            return .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_STRING:
            return .string(String(cString: data.assumingMemoryBound(to: CChar.self)))
        default:
            return nil
        }
    }

    // MARK: - Utils

    private func chk(_ code: Int32, _ what: String) {
        if code < 0 {
            let message = String(cString: mpv_error_string(code))
            DebugLog.log("mpv error (\(what)): \(message) [\(code)]")
        }
    }

    private static func getOpenGLProcAddress(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
        guard let name else { return nil }
        let symbolName = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
        let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
        return CFBundleGetFunctionPointerForName(bundle, symbolName)
    }
}
