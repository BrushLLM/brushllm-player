import AppKit

/// NSView container hosting the `VideoLayer`, plus file drag & drop.
///
/// The render context is created here, right after the layer's CGL context was
/// made current on this (main) thread — see `VideoLayer.createContext`.
final class VideoView: NSView {

    let videoLayer: VideoLayer
    private let controller: MPVController

    /// Called on the main thread when media files are dropped onto the view.
    var onOpenFiles: (([URL]) -> Void)?
    /// Called when a subtitle file is dropped onto the view.
    var onOpenSubtitle: ((URL) -> Void)?

    /// Called on the main thread whenever the view's aspect (width/height) changes;
    /// feeds fill-window mode.
    var onAspectChanged: ((CGFloat) -> Void)?

    /// Called with (resizing, viewWidth) when a live resize or fullscreen
    /// transition starts/ends; the control bar swaps to a snapshot while
    /// resizing (see PlayerCore.isLiveResizing).
    var onLiveResize: ((Bool, CGFloat) -> Void)?

    init(controller: MPVController) {
        self.controller = controller
        self.videoLayer = VideoLayer(controller: controller)
        super.init(frame: .zero)
        wantsLayer = true
        layer = videoLayer
        autoresizingMask = [.width, .height]
        // EDR-capable GL surface so HDR values survive the framebuffer.
        wantsExtendedDynamicRangeOpenGLSurface = true
        registerForDraggedTypes([.fileURL, .URL])
        controller.initRendering(layer: videoLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer.update(force: true)
    }

    // MARK: - Live-resize / fullscreen-transition freeze

    /// Dropping draws during a live resize keeps the drag smooth (see
    /// VideoLayer.isResizeFrozen); the stretched last frame bridges the
    /// gap and the end-of-resize redraw restores crisp output.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        videoLayer.isResizeFrozen = true
        onLiveResize?(true, bounds.width)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        videoLayer.isResizeFrozen = false
        onLiveResize?(false, bounds.width)
        videoLayer.update(force: true)
    }

    /// The fullscreen transition is one continuous animated resize — the
    /// same drawable-reallocation churn applies, so the freeze covers it
    /// too. Live-resize callbacks do not fire for it.
    private var fullscreenObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fullscreenObservers.forEach(NotificationCenter.default.removeObserver)
        fullscreenObservers.removeAll()
        guard let window else { return }
        let transitions: [Notification.Name] = [
            NSWindow.willEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification,
        ]
        let settled: [Notification.Name] = [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in transitions {
            fullscreenObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.videoLayer.isResizeFrozen = true
                    self.onLiveResize?(true, self.bounds.width)
                }
            )
        }
        for name in settled {
            fullscreenObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.videoLayer.isResizeFrozen = false
                    self.onLiveResize?(false, self.bounds.width)
                    self.videoLayer.update(force: true)
                }
            )
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Redraw at the new size even when paused (mpv has no new frame).
        // While playing, skip the forced redraw: mpv's render call blocks
        // on the frame-pace handshake, so one forced redraw per resize tick
        // backs up the serial GL queue and starves real frame renders —
        // visible as stutter during live resize and fullscreen. The next
        // frame (at most one frame interval away) renders at the new size;
        // until then the layer stretches the old content
        // (contentsGravity = .resizeAspectFill). nil (no file) still redraws.
        if controller.getFlag("pause") != false {
            videoLayer.update(force: true)
        }
        if newSize.height > 0 {
            onAspectChanged?(newSize.width / newSize.height)
        }
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrag(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrag(sender) ? .copy : []
    }

    private func acceptsDrag(_ sender: NSDraggingInfo) -> Bool {
        validDraggedFiles(sender) != nil
            || draggedSubtitle(sender) != nil
            || draggedNetworkURL(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let subtitle = draggedSubtitle(sender) {
            DispatchQueue.main.async { [onOpenSubtitle] in
                onOpenSubtitle?(subtitle)
            }
            return true
        }
        if let networkURL = draggedNetworkURL(sender) {
            DispatchQueue.main.async { [onOpenFiles] in
                onOpenFiles?([networkURL])
            }
            return true
        }
        guard let urls = validDraggedFiles(sender) else { return false }
        DispatchQueue.main.async { [onOpenFiles] in
            onOpenFiles?(urls)
        }
        return true
    }

    private let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "sub", "idx", "vtt", "sup"]

    private func validDraggedFiles(_ sender: NSDraggingInfo) -> [URL]? {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !items.isEmpty else { return nil }
        let files = items.filter { $0.isFileURL }
        return files.isEmpty ? nil : files
    }

    /// A dropped subtitle file, if any.
    private func draggedSubtitle(_ sender: NSDraggingInfo) -> URL? {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return nil }
        return items.first { url in
            url.isFileURL && subtitleExtensions.contains(url.pathExtension.lowercased())
        }
    }

    /// A dropped network URL (http/https), if any.
    private func draggedNetworkURL(_ sender: NSDraggingInfo) -> URL? {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return nil }
        return items.first { url in
            !url.isFileURL && (url.scheme == "http" || url.scheme == "https")
        }
    }
}
