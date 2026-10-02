import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main window: video surface, a persistent control bar below it (PotPlayer
/// style) and an optional playlist sidebar on the trailing edge.
struct PlayerWindowContent: View {
    @ObservedObject var player: PlayerCore
    @ObservedObject private var settings = AppSettings.shared

    /// Whether the playlist sidebar is shown.
    @State private var playlistVisible = false

    /// Whether the WebDAV browser sheet is shown.
    @State private var webDAVVisible = false

    var body: some View {
        VStack(spacing: 0) {
            // NOTE: no .animation modifier here. A value-scoped .animation on
            // this container still animates layout changes that originate
            // elsewhere (window live-resize re-proposes sizes every tick),
            // which made resizing visibly stutter — the playlist toggle is
            // already animated via withAnimation at the call site.
            HStack(spacing: 0) {
                videoArea
                if playlistVisible {
                    PlaylistPanel(player: player)
                        .frame(width: 264)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            ControlBar(
                player: player,
                togglePlaylist: { withAnimation { playlistVisible.toggle() } },
                isPlaylistVisible: playlistVisible
            )
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        // The normal-mode minimum matches the control bar's intrinsic size —
        // the mini window never drops below it, so the video area can never
        // collapse during state transitions. Below the full bar's ideal width
        // its secondary tools collapse via ViewThatFits.
        .frame(minWidth: player.isMiniWindow ? 300 : 640,
               minHeight: player.isMiniWindow ? 160 : 340)
        .onAppear {
            DebugLog.log("window onAppear, pending opens: \(OpenRequests.shared.pendingCount)")
            player.applyBrandTitle()
            player.open(OpenRequests.shared.consumeAll())
        }
        .task {
            // Fallback for open requests that raced ahead of the UI (Apple Events
            // and argv can both arrive before this view appears).
            try? await Task.sleep(for: .milliseconds(600))
            if player.isIdle {
                player.open(OpenRequests.shared.consumeAll())
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .brushPlayerOpenURLs)) { _ in
            player.open(OpenRequests.shared.consumeAll())
        }
        .onReceive(NotificationCenter.default.publisher(for: .brushPlayerShowWebDAV)) { _ in
            webDAVVisible = true
        }
        .sheet(isPresented: $webDAVVisible) {
            NetworkPanel { url in
                player.openURL(url)
            }
        }
        .contextMenu {
            videoContextMenu
        }
    }

    // MARK: - Video area

    private var videoArea: some View {
        VideoViewRepresentable(player: player)
            .background(Color.black)
            .overlay {
                if player.isIdle {
                    idleView
                } else if let error = player.loadErrorMessage {
                    errorView(error)
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
                                .foregroundStyle(.secondary)
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
                player.togglePlay()
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
        Toggle(L("controls.playlist", "Playlist"), isOn: Binding(
            get: { playlistVisible }, set: { _ in withAnimation { playlistVisible.toggle() } }))
        Button(L("controls.fullscreen", "Toggle Full Screen")) {
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

    private var idleView: some View {
        VStack(spacing: 12) {
            if let logo = Bundle.main.image(forResource: "AppIcon") {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(BrushLLMPlayerTheme.controlSeparator, lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 6)
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(BrushLLMPlayerTheme.accent.opacity(0.7))
            }
            Text(L("player.open-hint", "Open a media file to start playing"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture {
            OpenMediaPanel.present { urls in player.open(urls) }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(BrushPalette.orange)
            Text(L("player.load-failed", "Could not play this file"))
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(24)
        .background(BrushLLMPlayerTheme.controlMaterial, in: .rect(cornerRadius: 14))
        .padding(40)
    }
}

/// AppKit bridge for the mpv-rendering `VideoView`.
struct VideoViewRepresentable: NSViewRepresentable {
    let player: PlayerCore

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

/// Uniform type identifiers accepted by the player.
enum MediaTypes {
    static var all: [UTType] {
        var types: [UTType] = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .avi]
        for ext in ["mkv", "webm", "flac", "ape", "m3u8", "ts", "m2ts", "ogg", "opus", "aac", "wv", "iso", "iso9660"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }
}

extension Notification.Name {
    static let brushPlayerShowWebDAV = Notification.Name("dev.brushllm.showWebDAV")
}
