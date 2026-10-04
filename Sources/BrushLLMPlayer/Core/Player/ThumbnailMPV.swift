import Foundation
import AppKit
import Libmpv

/// A headless mpv instance dedicated to thumbnail generation.
///
/// The main player uses libmpv (which decodes every format), but the old
/// thumbnail service used AVAssetImageGenerator — which only opens QuickTime
/// containers (MP4/MOV). This instance loads the same file as the main
/// player and renders a frame at the exact hovered time into an off-screen
/// memory buffer using libmpv's software render API (MPV_RENDER_API_TYPE_SW).
/// Works for every format mpv can play, with no window or GL context.
///
/// Lifecycle: created lazily on first thumbnail request, loads the file
/// alongside the main player, destroyed when playback goes idle.
final class ThumbnailMPV {

    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var loadedPath: String?
    private let processingQueue = DispatchQueue(label: "dev.brushllm.player.thumbnail", qos: .userInteractive)

    /// Fixed thumbnail size (16:9-ish card in the UI).
    private let thumbWidth = 256
    private let thumbHeight = 144

    // MARK: - Lifecycle

    deinit {
        shutdown()
    }

    func shutdown() {
        // Serialized against captureFrame/loadFile: freeing the handle from
        // another thread (idle-active fires on the main thread mid-seek on
        // network streams) while captureFrame polls it crashed with
        // EXC_BAD_ACCESS in mpv_get_property_string.
        processingQueue.sync {
            if let rc = renderContext {
                mpv_render_context_free(rc)
                renderContext = nil
            }
            if let mpv {
                mpv_terminate_destroy(mpv)
                self.mpv = nil
            }
            loadedPath = nil
        }
    }

    /// Creates and initializes the headless instance plus a software render
    /// context (no window, no audio, no scripts).
    private func ensureInstance() -> OpaquePointer? {
        if let mpv, renderContext != nil { return mpv }
        guard let handle = mpv_create() else { return nil }

        mpv_set_option_string(handle, "config", "no")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "load-scripts", "no")
        mpv_set_option_string(handle, "terminal", "no")
        mpv_set_option_string(handle, "msg-level", "all=error")
        // vo=libmpv is required for the software render context to produce frames.
        mpv_set_option_string(handle, "vo", "libmpv")
        mpv_set_option_string(handle, "ao", "null")
        mpv_set_option_string(handle, "hwdec", "auto-safe")
        mpv_set_option_string(handle, "pause", "yes")
        // Skip to the requested position fast (keyframe accuracy is enough
        // for a 160px preview; exact seek happens below for the final frame).
        mpv_set_option_string(handle, "hr-seek", "yes")

        guard mpv_initialize(handle) >= 0 else {
            mpv_destroy(handle)
            return nil
        }

        // Software render context: renders frames into a caller-provided buffer.
        let apiType = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_SW as NSString).utf8String)
        var advanced: CInt = 1
        let createResult: Int32 = withUnsafeMutablePointer(to: &advanced) { advanced in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advanced),
                mpv_render_param(),
            ]
            var ctx: OpaquePointer?
            let res = mpv_render_context_create(&ctx, handle, &params)
            self.renderContext = ctx
            return res
        }
        guard createResult >= 0, renderContext != nil else {
            DebugLog.log("thumb: render context create failed \(createResult)")
            mpv_terminate_destroy(handle)
            return nil
        }

        mpv = handle
        return handle
    }

    /// Loads a file into the thumbnail instance (called when the main player
    /// loads a file). Safe to call repeatedly — skips if already loaded.
    func loadFile(_ path: String) {
        processingQueue.sync {
            guard let handle = ensureInstance() else { return }
            if loadedPath == path { return }
            loadedPath = path
            send(handle, ["loadfile", path, "replace"])
            waitForLoaded(handle)
        }
    }

    // MARK: - Frame capture

    /// Renders the frame at the exact time into an off-screen buffer and
    /// returns it as an NSImage. Synchronous — call from a background queue.
    func captureFrame(at time: Double) -> NSImage? {
        processingQueue.sync {
            guard let handle = ensureInstance(), let renderContext, loadedPath != nil else {
                DebugLog.log("thumb: not ready (instance/path)")
                return nil
            }

            // Seek to the exact position in the already-loaded file.
            let target = max(0, time)
            send(handle, ["seek", String(format: "%.3f", target), "absolute+exact"])

            // Wait until the seek lands (time-pos reflects the target).
            waitForSeek(handle, target: target)

            // Render one frame into the software buffer. After a seek the new
            // frame is only produced once mpv processes it, so poll the update
            // flag until a fresh frame is available (with a timeout).
            let stride = Int(thumbWidth) * 4
            var pixels = [UInt8](repeating: 0, count: stride * Int(thumbHeight))
            var rendered = false
            var tries = 0
            while tries < 60, !rendered {
                guard handle == self.mpv else { return nil }
                let flags = mpv_render_context_update(renderContext)
                if flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
                    rendered = renderOnce(renderContext, width: thumbWidth, height: thumbHeight, stride: stride, pixels: &pixels)
                }
                if !rendered {
                    usleep(10_000)
                    tries += 1
                }
            }
            guard rendered else {
                DebugLog.log("thumb: render failed (no frame after seek)")
                return nil
            }

            return makeImage(pixels: pixels, width: thumbWidth, height: thumbHeight, stride: stride)
        }
    }

    // MARK: - Helpers

    /// Renders one frame into `pixels` via the SW render API.
    ///
    /// mpv reads every render parameter synchronously inside
    /// `mpv_render_context_render`, so the stack pointers below stay valid for
    /// the whole call (this is the documented usage pattern for the SW API).
    private func renderOnce(_ ctx: OpaquePointer, width: Int, height: Int, stride: Int, pixels: inout [UInt8]) -> Bool {
        var size: [CInt] = [Int32(width), Int32(height)]
        var formatName = "rgb0"
        var strideValue = stride
        var ok = false
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: &size),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: &formatName),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: &strideValue),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                mpv_render_param(),
            ]
            ok = mpv_render_context_render(ctx, &params) >= 0
        }
        return ok
    }

    private func send(_ handle: OpaquePointer, _ args: [String]) {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        defer {
            for case let ptr? in cargs { free(UnsafeMutablePointer(mutating: ptr)) }
        }
        _ = mpv_command(handle, &cargs)
    }

    private func waitForLoaded(_ handle: OpaquePointer) {
        var attempts = 0
        while attempts < 100 {
            guard handle == self.mpv else { return }
            let idle = mpv_get_property_string(handle, "idle-active")
            let isIdle = idle.map { String(cString: $0) == "yes" } ?? true
            mpv_free(idle)
            if !isIdle { break }
            usleep(10_000)
            attempts += 1
        }
    }

    private func waitForSeek(_ handle: OpaquePointer, target: Double) {
        var attempts = 0
        while attempts < 80 {
            // Bail when a shutdown reset the instance mid-poll.
            guard handle == self.mpv else { return }
            let pos = mpv_get_property_string(handle, "time-pos")
            let value = pos.flatMap { Double(String(cString: $0)) }
            mpv_free(pos)
            if let value, abs(value - target) < 2.0 { return }
            usleep(10_000)
            attempts += 1
        }
    }

    /// Builds an NSImage from an rgb0 buffer (R at byte 0; 4th byte unused).
    private func makeImage(pixels: [UInt8], width: Int, height: Int, stride: Int) -> NSImage? {
        // rgb0 little-endian memory layout = byte order [r, g, b, x] which
        // matches CGBitmapInfo byteOrder32Little + premultipliedLast.
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
