import AppKit
import OpenGL.GL
import OpenGL.GL3
import Libmpv

/// OpenGL layer that renders mpv video frames.
///
/// Follows IINA's `ViewLayer`: drawing is triggered from a background queue
/// (`mpvGLQueue`) rather than the main thread, because main-thread rendering
/// makes UI animations sluggish. `display()` is called directly on that queue
/// inside an explicit `CATransaction` (an implicit transaction off the main
/// thread is not allowed).
final class VideoLayer: CAOpenGLLayer {

    private unowned let controller: MPVController

    /// Dedicated queue for GL work; `display()` runs here during playback.
    private let mpvGLQueue = DispatchQueue(label: "dev.brushllm.player.mpvgl", qos: .userInteractive)

    /// Serializes `display()` between the GL queue and the main thread.
    private let displayLock = NSRecursiveLock()

    let cglContext: CGLContextObj
    private let cglPixelFormat: CGLPixelFormatObj
    private let bufferDepth: GLint

    /// The framebuffer mpv rendered into last; AppKit-managed, captured in draw.
    private var fbo: GLint = 0

    /// When `true` the next draw proceeds even if mpv has no new frame
    /// (window resize, backing-store change).
    private var forceDraw = false

    init(controller: MPVController) {
        self.controller = controller
        let (pixelFormat, depth) = VideoLayer.createPixelFormat()
        self.cglPixelFormat = pixelFormat
        self.bufferDepth = depth
        self.cglContext = VideoLayer.createContext(pixelFormat)
        super.init()
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        backgroundColor = NSColor.black.cgColor
        isAsynchronous = false
        // When the layer resizes but mpv hasn't produced a new frame yet, stretch
        // the old content instead of showing black.
        contentsGravity = .resizeAspectFill
    }

    override init(layer: Any) {
        // Shadow copy created by AppKit (e.g. on backing-store changes); shares
        // the same GL context and pixel format as the original.
        let previous = layer as! VideoLayer
        controller = previous.controller
        cglPixelFormat = previous.cglPixelFormat
        cglContext = previous.cglContext
        bufferDepth = previous.bufferDepth
        super.init(layer: layer)
        autoresizingMask = previous.autoresizingMask
        backgroundColor = previous.backgroundColor
        contentsGravity = previous.contentsGravity
        wantsExtendedDynamicRangeContent = previous.wantsExtendedDynamicRangeContent
        colorspace = previous.colorspace
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Draw cycle

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        // When in live resize, skip all drawing calls on the main thread.
        // Setting isAsynchronous = true is enough to prevent jittering.
        guard !(inLiveResize && Thread.isMainThread) else { return false }
        if !inLiveResize {
            // Only clear the async mode once a draw is about to happen —
            // clearing it earlier can flash black when leaving fullscreen.
            isAsynchronous = false
        }
        if forceDraw {
            forceDraw = false
            return true
        }
        return controller.shouldRenderUpdateFrame()
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

        var boundFBO: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &boundFBO)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        // AppKit may bind FBO 0 (default framebuffer) or its own FBO; remember the
        // last non-zero one for the case where a later draw binds 0.
        if boundFBO != 0 {
            fbo = boundFBO
        }

        controller.render(fbo: boundFBO != 0 ? boundFBO : fbo,
                          width: viewport[2],
                          height: viewport[3],
                          depth: bufferDepth)
        glFlush()

        // Deliver a pending screenshot request with the freshly rendered frame.
        let handler = snapshotLock.withLock { () -> ((NSImage?) -> Void)? in
            let handler = pendingSnapshotHandler
            pendingSnapshotHandler = nil
            return handler
        }
        if let handler {
            let image = framebufferSnapshot(width: Int(viewport[2]), height: Int(viewport[3]))
            handler(image)
        }
    }

    /// Called by `MPVController`'s render update callback (an mpv-internal thread):
    /// schedules a display on the GL queue.
    func renderUpdate() {
        update()
    }

    /// Enables extended dynamic range on the layer for HDR playback. The layer
    /// colorspace must be declared as PQ so the system color-matches mpv's
    /// PQ-encoded frames — without it the raw PQ values display crushed/dark.
    /// `nil` disables colormatching (plain sRGB pass-through).
    func setHDR(_ enabled: Bool) {
        wantsExtendedDynamicRangeContent = enabled
        colorspace = enabled ? CGColorSpace(name: CGColorSpace.itur_2100_PQ) : nil
        update(force: true)
    }

    /// Indicates whether the view is being rendered as part of a live
    /// resizing operation (IINA's ViewLayer.inLiveResize).
    ///
    /// While live-resizing, `isAsynchronous` is turned on so CA drives
    /// canDraw/draw on its own render thread, synchronized with the
    /// display refresh — the window server expects layer updates on the
    /// display cycle, so drawing in cooperation with it keeps the drag
    /// smooth (drawing from our GL queue at arbitrary timings fought it
    /// and made resizing stutter). `canDraw` also skips main-thread
    /// draws during the resize.
    var inLiveResize: Bool = false {
        didSet {
            if inLiveResize {
                isAsynchronous = true
            }
            update(force: true)
        }
    }

    /// Triggers a redraw. Safe from any thread.
    func update(force: Bool = false) {
        mpvGLQueue.async { [self] in
            if force {
                forceDraw = true
            }
            display()
        }
    }

    // MARK: - Snapshot

    private let snapshotLock = NSLock()
    private var pendingSnapshotHandler: ((NSImage?) -> Void)?

    /// Captures the next rendered frame as an `NSImage`. Forces a redraw so
    /// this works while paused. Runs on the GL queue inside `draw`.
    func captureSnapshot() async -> NSImage? {
        await withCheckedContinuation { continuation in
            snapshotLock.lock()
            // Drop any previous in-flight request — only the latest caller wins.
            let previous = pendingSnapshotHandler
            pendingSnapshotHandler = { image in
                continuation.resume(returning: image)
            }
            snapshotLock.unlock()
            previous?(nil)
            update(force: true)
        }
    }

    /// Reads pixels back from the layer's framebuffer and flips rows into a
    /// top-down CGImage. MPVKit's FFmpeg lacks image encoders, so screenshots
    /// are taken from the GL framebuffer directly (IINA's approach).
    private func framebufferSnapshot(width: Int, height: Int) -> NSImage? {
        let bytesPerRow = width * 4
        var pixels = Data(count: height * bytesPerRow)

        var prevReadFBO: GLint = 0
        glGetIntegerv(GLenum(GL_READ_FRAMEBUFFER_BINDING), &prevReadFBO)
        defer { glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(prevReadFBO)) }

        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(fbo))
        glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
        glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)

        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            glReadPixels(0, 0, GLsizei(width), GLsizei(height),
                         GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), base)

            // OpenGL origin is bottom-left; CGImage expects top-left. Flip in place.
            var temp = [UInt8](repeating: 0, count: bytesPerRow)
            temp.withUnsafeMutableBufferPointer { tempBuffer in
                let swap = UnsafeMutableRawPointer(tempBuffer.baseAddress!)
                for row in 0..<(height / 2) {
                    let top = base.advanced(by: row * bytesPerRow)
                    let bottom = base.advanced(by: (height - 1 - row) * bytesPerRow)
                    memcpy(swap, top, bytesPerRow)
                    memcpy(top, bottom, bytesPerRow)
                    memcpy(bottom, swap, bytesPerRow)
                }
            }
        }

        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    override func display() {
        displayLock.lock()
        defer { displayLock.unlock() }

        if Thread.isMainThread {
            super.display()
        } else {
            // Off the main thread an explicit transaction is mandatory, otherwise
            // implicit-transaction assertions fire.
            CATransaction.begin()
            super.display()
            CATransaction.commit()
        }
        CATransaction.flush()
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        cglPixelFormat
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        cglContext
    }

    // MARK: - GL context creation

    private static func createPixelFormat() -> (CGLPixelFormatObj, GLint) {
        let versions: [CGLOpenGLProfile] = [kCGLOGLPVersion_3_2_Core, kCGLOGLPVersion_Legacy]
        var lastError = CGLError(rawValue: 0)
        for version in versions {
            let attributes: [CGLPixelFormatAttribute] = [
                kCGLPFAOpenGLProfile,
                CGLPixelFormatAttribute(version.rawValue),
                kCGLPFAAccelerated,
                kCGLPFADoubleBuffer,
                kCGLPFABackingStore,
                kCGLPFASupportsAutomaticGraphicsSwitching,
                CGLPixelFormatAttribute(0),
            ]
            var pixelFormat: CGLPixelFormatObj?
            var count: GLint = 0
            let error = CGLChoosePixelFormat(attributes, &pixelFormat, &count)
            if error == kCGLNoError, let pixelFormat {
                return (pixelFormat, 8)
            }
            lastError = error
        }
        fatalError("BrushLLMPlayer: cannot create OpenGL pixel format (error: \(String(cString: CGLErrorString(lastError))))")
    }

    private static func createContext(_ pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        var context: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &context)
        guard let context else {
            fatalError("BrushLLMPlayer: cannot create OpenGL context")
        }
        // Sync to vertical retrace.
        var swapInterval: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &swapInterval)
        // Multi-threaded GL engine.
        CGLEnable(context, kCGLCEMPEngine)
        // The render context is created right after this while the context is
        // still current on the creating thread.
        CGLSetCurrentContext(context)
        return context
    }
}
