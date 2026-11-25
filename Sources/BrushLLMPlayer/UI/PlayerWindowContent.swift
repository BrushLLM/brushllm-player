import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The desktop shell keeps navigation alongside the playback workspace.
struct PlayerWindowContent: View {
    @ObservedObject var player: PlayerCore
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var section: PlayerSidebarSection = .playlist
    @State private var narrow = false
    @State private var expandedWhenNarrow = false
    @State private var collapsedWhenWide = false
    @State private var networkTab: NetworkPanel.Tab?
    @State private var subtitleSearchVisible = false
    @State private var barSnapshot: NSImage?
    @State private var fullscreenControlsVisible = false
    @State private var pointerAtFullscreenControls = false
    @State private var usingFullscreenControls = false
    @FocusState private var fullscreenRevealFocused: Bool

    private var viewing: Bool { player.isMiniWindow || player.isFullscreen }

    var body: some View {
        GeometryReader { geometry in
            let narrowLayout = geometry.size.width < 800
            let compact = narrowLayout ? !expandedWhenNarrow : collapsedWhenWide
            HStack(spacing: 0) {
                if !viewing {
                    PlayerSidebar(player: player, section: section, compact: compact,
                                  onSelect: reveal, onOpenFiles: openFiles,
                                  onOpenNetwork: { networkTab = $0 })
                        .id(settings.language)
                }

                VStack(spacing: 0) {
                    if !viewing { workspaceHeader(compact: compact, narrow: narrowLayout) }
                    videoArea(showSources: compact && !viewing)
                        .clipShape(RoundedRectangle(cornerRadius: viewing ? 0 : 12))
                        .padding(.horizontal, viewing ? 0 : 16)
                        .contextMenu { videoContextMenu }
                        .onHover { hovering in
                            if hovering && player.isFullscreen { pointerAtFullscreenControls = false }
                        }
                        .layoutPriority(1)
                    if !player.isFullscreen || fullscreenControlsVisible {
                        controlBar.onHover { hovering in
                            if player.isFullscreen { pointerAtFullscreenControls = hovering }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottom) {
                if player.isFullscreen && !fullscreenControlsVisible { fullscreenRevealHandle }
            }
            .onChange(of: player.isFullscreen) { _, fullscreen in
                if !fullscreen {
                    fullscreenControlsVisible = false
                    pointerAtFullscreenControls = false
                    usingFullscreenControls = false
                }
            }
            .onChange(of: narrowLayout, initial: true) { _, value in
                narrow = value
            }
            .onChange(of: player.isLiveResizing) { _, resizing in
                let railWidth: CGFloat = viewing ? 0 : (compact ? 64 : 200)
                barSnapshot = resizing && !player.isFullscreen
                    ? renderBarSnapshot(width: geometry.size.width - railWidth) : nil
            }
        }
        .task(id: shouldHideFullscreenControls) {
            guard shouldHideFullscreenControls else { return }
            try? await Task.sleep(for: .milliseconds(180))
            if !Task.isCancelled && shouldHideFullscreenControls { fullscreenControlsVisible = false }
        }
        .background(viewing ? BrushLLMPlayerTheme.videoMatte : BrushLLMPlayerTheme.window)
        .frame(minWidth: player.isMiniWindow ? 300 : 640, minHeight: player.isMiniWindow ? 160 : 340)
        .onExitCommand {
            if player.isFullscreen { player.toggleFullscreen() }
            else if player.isMiniWindow { player.toggleMiniWindow() }
        }
        .onReceive(OpenRequests.shared.arrivals) { _ in openQueuedMedia() }
        .onReceive(NotificationCenter.default.publisher(for: .brushPlayerShowPlaylist)) { _ in
            reveal(.playlist)
        }
        .onReceive(NotificationCenter.default.publisher(for: .brushPlayerShowWebDAV)) { _ in
            networkTab = .servers
        }
        .onReceive(NotificationCenter.default.publisher(for: .brushPlayerShowSubtitleSearch)) { _ in
            subtitleSearchVisible = true
        }
        .sheet(item: $networkTab) { tab in
            NetworkPanel(initialTab: tab, onPlay: player.openURL)
        }
    }

    private func reveal(_ destination: PlayerSidebarSection) {
        section = destination
        if narrow { expandedWhenNarrow = true }
        else { collapsedWhenWide = false }
        if player.isFullscreen {
            player.toggleFullscreen()
        } else if player.isMiniWindow {
            player.toggleMiniWindow()
        }
    }

    private func openFiles() {
        OpenMediaPanel.present { player.open($0) }
    }

    private func openQueuedMedia() {
        guard player.videoView?.window != nil else { return }
        player.open(OpenRequests.shared.consumeAll())
    }

    private func workspaceHeader(compact: Bool, narrow: Bool) -> some View {
        let title = player.mediaTitle.isEmpty ? player.fileName : player.mediaTitle
        return HStack(spacing: 10) {
            PlayerIconButton(icon: "sidebar.left",
                             help: compact ? L("player.sidebar-expand", "Expand sidebar") : L("player.sidebar-collapse", "Collapse sidebar")) {
                if narrow { expandedWhenNarrow = compact }
                else { collapsedWhenWide = !compact }
            }
            Text(player.isIdle || title.isEmpty ? L("player.workspace", "Player") : title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if !player.isIdle {
                let openTitle = L("player.open-files", "Open files…")
                Button(action: openFiles) {
                    Label(openTitle, systemImage: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .background(BrushLLMPlayerTheme.hoverFill, in: .rect(cornerRadius: DesignRadius.row))
                }
                .buttonStyle(PressedDimButtonStyle())
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .help(openTitle)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    @ViewBuilder
    private var controlBar: some View {
        if player.isLiveResizing, !player.isFullscreen, let barSnapshot {
            // Do not lay out the live controls during the window animation.
            Image(nsImage: barSnapshot)
                .resizable()
                .frame(height: barSnapshot.size.height)
                .accessibilityHidden(true)
        } else {
            liveControlBar.id(settings.language)
        }
    }

    private var liveControlBar: some View {
        ControlBar(player: player, showChapters: { reveal(.chapters) },
                   onFullscreenInteractionChange: { usingFullscreenControls = $0 })
            .environment(\.colorScheme, viewing ? .dark : colorScheme)
    }

    private var shouldHideFullscreenControls: Bool {
        player.isFullscreen && fullscreenControlsVisible && !pointerAtFullscreenControls && !usingFullscreenControls
    }

    private func revealFullscreenControls() {
        pointerAtFullscreenControls = true
        fullscreenControlsVisible = true
    }

    private var fullscreenRevealHandle: some View {
        let label = L("player.options", "Playback options")
        return Button(action: revealFullscreenControls) {
            Color.clear
                .frame(height: 8)
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
                .overlay(alignment: .bottomTrailing) {
                    if fullscreenRevealFocused {
                        Text(label)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .foregroundStyle(BrushLLMPlayerTheme.accentText)
                            .background(BrushLLMPlayerTheme.selectionFill, in: .rect(cornerRadius: DesignRadius.row))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain)
        .focused($fullscreenRevealFocused)
        .accessibilityLabel(label)
        .onHover { hovering in
            if hovering { revealFullscreenControls() }
        }
        .environment(\.colorScheme, .dark)
    }

    private func renderBarSnapshot(width: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: liveControlBar)
        renderer.proposedSize = .init(width: width, height: nil)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 1
        return renderer.nsImage
    }

    private func videoArea(showSources: Bool) -> some View {
        VideoViewRepresentable(player: player, onWindowAttached: openQueuedMedia)
            .background(BrushLLMPlayerTheme.videoMatte)
            .overlay {
                if let error = player.loadErrorMessage {
                    errorView(error)
                } else if player.isIdle {
                    idleView(showSources: showSources)
                }
            }
            .overlay(alignment: .top) {
                if player.isBuffering && !player.isIdle {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(BrushLLMPlayerTheme.accent)
                            .scaleEffect(1.2)
                        // A load stuck this long is usually a pending
                        // file-access permission prompt (TCC).
                        if player.bufferingSeconds > 10 {
                            Text(L("player.slow-load-hint", "Still loading… check file access permissions in System Settings → Privacy & Security"))
                                .font(.caption)
                                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 360)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(BrushLLMPlayerTheme.controlMaterial, in: .rect(cornerRadius: 8))
                        }
                    }
                    .padding(.top, 24)
                }
            }
            .contentShape(.rect)
            .onTapGesture(count: 2) {
                player.toggleFullscreen()
            }
            .onTapGesture {
                if !player.isIdle { player.togglePlay() }
            }
            .sheet(isPresented: $subtitleSearchVisible) {
                SubtitleSearchPanel(player: player)
            }
    }

    // MARK: - Right-click menu (PotPlayer-style full menu)

    @ViewBuilder
    private var videoContextMenu: some View {
        Button(player.isPaused ? L("menu.play", "Play") : L("menu.pause", "Pause")) {
            player.togglePlay()
        }
        Button(L("menu.stop", "Stop")) { player.stop() }
        Divider()
        Button(L("menu.open", "Open…")) {
            OpenMediaPanel.present { urls in player.open(urls) }
        }
        Button(L("menu.open-url", "Open URL…")) {
            OpenURLPanel.present { player.openURL($0) }
        }
        Divider()
        Button(L("menu.next", "Next")) { player.playlistNext() }
        Button(L("menu.previous", "Previous")) { player.playlistPrevious() }
        Divider()
        Menu(L("controls.speed", "Playback speed")) {
            ForEach(PlaybackSpeedPanel.rates(including: player.speed), id: \.self) { rate in
                Button {
                    player.speed = rate
                } label: {
                    if rate == player.speed {
                        Label(PlaybackSpeedPanel.label(rate), systemImage: "checkmark")
                    } else {
                        Text(PlaybackSpeedPanel.label(rate))
                    }
                }
            }
        }
        Divider()
        if !player.audioTracks.isEmpty {
            Menu(L("menu.audio", "Audio")) {
                Button(L("panel.tracks.off", "Off")) { player.setAudioTrack(nil) }
                ForEach(player.audioTracks) { track in
                    Button(track.label) { player.setAudioTrack(track.id) }
                }
            }
        }
        Menu(L("menu.subtitle", "Subtitles")) {
            Button(L("panel.tracks.off", "Off")) { player.setSubtitleTrack(nil) }
            ForEach(player.subtitleTracks) { track in
                Button(track.label) { player.setSubtitleTrack(track.id) }
            }
            Divider()
            Button(L("menu.load-subtitle", "Load Subtitle File…")) {
                SubtitlePanel.present { url in player.loadExternalSubtitle(url) }
            }
            Button(L("subtitle.online", "Online Subtitles…")) {
                player.searchOnlineSubtitles()
            }
        }
        Menu(L("menu.video", "Video")) {
            aspectRows
            Divider()
            Toggle(L("menu.ontop", "Always on Top"), isOn: Binding(
                get: { player.isOnTop }, set: { player.isOnTop = $0 }))
        }
        Divider()
        Menu(L("menu.loop", "Loop")) {
            ForEach(LoopMode.allCases) { mode in
                Button(loopLabel(mode)) { player.setLoopMode(mode) }
            }
        }
        Menu(L("menu.ab-loop", "A-B Loop")) {
            Button(L("ab-loop.set-a", "Set Point A")) { player.setABLoopA() }
            Button(L("ab-loop.set-b", "Set Point B")) { player.setABLoopB() }
            Divider()
            Button(L("ab-loop.clear", "Clear A-B Loop")) { player.clearABLoop() }
        }
        Divider()
        Button(L("menu.screenshot", "Screenshot")) { player.screenshot() }
        if player.isRecording {
            Button(L("menu.stop-recording", "Stop Recording")) { player.stopRecording() }
        } else {
            Button(L("menu.start-recording", "Record To File…")) { player.startRecording() }
        }
        Button(L("menu.bookmark-add", "Add Bookmark")) { player.addBookmark() }
        Divider()
        Button(L("controls.playlist", "Playlist")) { reveal(.playlist) }
        Button(player.isFullscreen ? L("player.fullscreen-exit", "Exit full screen")
                                   : L("controls.fullscreen", "Toggle Full Screen")) {
            player.toggleFullscreen()
        }
    }

    @ViewBuilder
    private var aspectRows: some View {
        Button(L("video.aspect.fit", "Fit to Window")) { player.aspectMode = .fit }
        Button(L("video.aspect.fill", "Fill Window")) { player.aspectMode = .fill }
        Button(L("video.aspect.stretch", "Stretch to Window")) { player.aspectMode = .stretch }
        ForEach(["4:3", "16:9", "2.35:1", "1:1"], id: \.self) { ratio in
            Button(ratio) {
                player.aspectMode = .custom
                player.aspectOverride = ratio
            }
        }
    }

    private func loopLabel(_ mode: LoopMode) -> String {
        switch mode {
        case .off: return L("loop.off", "No Loop")
        case .file: return L("loop.file", "Loop File")
        case .playlist: return L("loop.playlist", "Loop Playlist")
        }
    }

    // MARK: - Idle & error

    private func idleView(showSources: Bool) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 29, weight: .regular))
                    .foregroundStyle(BrushLLMPlayerTheme.viewingAccent)
                    .frame(width: 58, height: 52)
                    .background(BrushLLMPlayerTheme.viewingSelection, in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(L("player.open-hint", "Open a media file to start playing"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BrushLLMPlayerTheme.viewingText)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(L("player.drag-hint", "…or drag media files into the window"))
                    .font(.system(size: 13))
                    .foregroundStyle(BrushLLMPlayerTheme.viewingTextSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    openFilesButton
                    if showSources {
                        Button(L("player.sources", "Sources")) { reveal(.sources) }
                            .buttonStyle(.bordered)
                            .tint(BrushLLMPlayerTheme.viewingAccent)
                    }
                }
                .padding(.top, 4)
            }
            openFilesButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrushLLMPlayerTheme.videoMatte)
    }

    private var openFilesButton: some View {
        Button(action: openFiles) {
            Label(L("player.open-files", "Open files…"), systemImage: "folder")
        }
        .buttonStyle(AccentProminentButtonStyle())
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(BrushLLMPlayerTheme.warning)
            Text(L("player.load-failed", "Could not play this file"))
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            openFilesButton
        }
        .padding(24)
        .background(BrushLLMPlayerTheme.controlMaterial, in: .rect(cornerRadius: DesignRadius.sheet))
        .padding(40)
    }
}

/// AppKit bridge for the mpv-rendering `VideoView`.
struct VideoViewRepresentable: NSViewRepresentable {
    let player: PlayerCore
    let onWindowAttached: () -> Void

    func makeNSView(context: Context) -> VideoView {
        let view = VideoView(controller: player.mpv)
        view.onOpenFiles = { urls in
            player.open(urls)
        }
        view.onOpenSubtitle = { url in
            player.loadExternalSubtitle(url)
        }
        view.onAspectChanged = { aspect in
            player.windowAspect = aspect
        }
        view.onLiveResize = { player.setDragResizing($0) }
        view.onWindowChanged = { [weak player, weak view] in
            DispatchQueue.main.async {
                guard let player, let view, player.videoView === view else { return }
                player.attachWindow(view.window)
                if view.window != nil { onWindowAttached() }
            }
        }
        player.videoLayer = view.videoLayer
        player.videoView = view
        return view
    }

    func updateNSView(_ nsView: VideoView, context: Context) {}
}

/// Shared "Open media" file panel.
enum OpenMediaPanel {
    static func present(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = MediaTypes.all
        if panel.runModal() == .OK {
            completion(panel.urls)
        }
    }
}

/// "Open URL" input sheet.
enum OpenURLPanel {
    static func present(completion: @escaping (URL) -> Void) {
        let alert = NSAlert()
        alert.messageText = L("menu.open-url", "Open URL…")
        alert.informativeText = L("panel.url.hint", "Direct media link or m3u8/HLS address")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "https://example.com/video.m3u8"
        alert.accessoryView = input
        alert.addButton(withTitle: L("panel.url.open", "Play"))
        alert.addButton(withTitle: L("panel.cancel", "Cancel"))
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn,
              !input.stringValue.isEmpty,
              let url = URL(string: input.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        completion(url)
    }
}

/// "Load subtitle file" panel.
enum SubtitlePanel {
    static func present(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = []
        for ext in ["srt", "ass", "ssa", "sub", "idx", "vtt", "sup"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        panel.allowedContentTypes = types
        panel.message = L("panel.subtitle.hint", "Choose a subtitle file")
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }
}

extension Notification.Name {
    static let brushPlayerShowWebDAV = Notification.Name("dev.brushllm.showWebDAV")
    /// Opens the playlist sidebar (e.g. after adding a folder's files).
    static let brushPlayerShowPlaylist = Notification.Name("dev.brushllm.showPlaylist")
    /// Opens the online-subtitle search sheet.
    static let brushPlayerShowSubtitleSearch = Notification.Name("dev.brushllm.showSubtitleSearch")
}
