import SwiftUI
import AppKit

@main
struct BrushLLMPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = PlayerCore()

    var body: some Scene {
        // A single main window: unlike WindowGroup, the Window scene does not
        // spawn an extra window when macOS delivers a file-open event.
        Window("BrushLLM Player", id: "main") {
            // No min-size here: PlayerWindowContent owns the constraint and
            // widens/narrows it with isMiniWindow — a fixed 640 here clamped
            // the 420pt mini window to 640 and overrode the inner values.
            PlayerWindowContent(player: player)
                .onReceive(NotificationCenter.default.publisher(for: .brushPlayerOpenURLs)) { _ in
                    player.open(OpenRequests.shared.consumeAll())
                }
        }
        .commands {
            // Reading published state here makes the scene re-evaluate when
            // tracks/playlist/chapters change, rebuilding the dynamic menus.
            BrushLLMPlayerCommands(
                player: player,
                refreshToken: player.subtitleTracks.count
                    + player.audioTracks.count
                    + player.playlist.count
                    + player.chapters.count
                    + (player.abLoopA == nil ? 0 : 1)
                    + (player.abLoopB == nil ? 0 : 1)
            )
        }

        Settings {
            SettingsWindow()
        }

        Window(L("settings.about", "About"), id: "about") {
            AboutWindow()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 430)
    }
}


/// App-level behaviors: quit when the last window closes, accept files
/// dropped onto the Dock icon or passed as command-line arguments, and terminate
/// cleanly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files or URLs passed on the command line:
        // `BrushLLMPlayer /path/to/video.mkv https://example.com/stream.m3u8`
        let arguments = CommandLine.arguments.dropFirst().compactMap { argument -> URL? in
            if argument.hasPrefix("http://") || argument.hasPrefix("https://") {
                return URL(string: argument)
            }
            return FileManager.default.fileExists(atPath: argument) ? URL(fileURLWithPath: argument) : nil
        }
        DebugLog.log("didFinishLaunching, argv: \(arguments)")
        if !arguments.isEmpty {
            OpenRequests.shared.add(arguments)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        DebugLog.log("application(open urls): \(urls)")
        OpenRequests.shared.add(urls)
    }

    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        PlayerCore.sharedForSettings?.shutdown()
        Task { @MainActor in
            async let smb = SMBClient.shutdown(timeout: 3)
            async let discs = DiscImageResource.shutdown(timeout: 3)
            _ = await (smb, discs)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerCore.sharedForSettings?.shutdown()
        PlaybackStore.shared.flush()
    }
}

/// Files requested to open before or after the UI is ready. Apple Events can
/// arrive before the SwiftUI scene subscribes, so requests are also queued here.
final class OpenRequests {
    static let shared = OpenRequests()
    private var queue: [URL] = []

    func add(_ urls: [URL]) {
        queue.append(contentsOf: urls)
        NotificationCenter.default.post(name: .brushPlayerOpenURLs, object: nil, userInfo: ["urls": urls])
    }

    /// Returns and clears every pending file.
    func consumeAll() -> [URL] {
        let urls = queue
        queue.removeAll()
        return urls
    }

    var pendingCount: Int { queue.count }
}

extension Notification.Name {
    static let brushPlayerOpenURLs = Notification.Name("dev.brushllm.player.openURLs")
}

/// Menu bar commands with Apple-standard shortcuts. `refreshToken` is read
/// from the App's scene body so the commands rebuild when the player's
/// track/playlist data changes.
struct BrushLLMPlayerCommands: Commands {
    let player: PlayerCore
    var refreshToken: Int = 0
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("about.menu", "About BrushLLM Player")) {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "about")
            }
        }

        CommandGroup(replacing: .newItem) {
            Button(L("menu.open", "Open…")) {
                OpenMediaPanel.present { urls in
                    player.open(urls)
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Button(L("menu.open-url", "Open URL…")) {
                OpenURLPanel.present { url in
                    player.openURL(url)
                }
            }
            .keyboardShortcut("u", modifiers: .command)

            Button(L("menu.media-servers", "Media Servers…")) {
                NotificationCenter.default.post(name: .brushPlayerShowWebDAV, object: nil)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandMenu(L("menu.playback", "Playback")) {
            Button(player.isPaused
                   ? L("menu.play", "Play")
                   : L("menu.pause", "Pause")) {
                player.togglePlay()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player.isIdle && player.playlist.isEmpty)

            Button(L("menu.stop", "Stop")) {
                player.stop()
            }
            .disabled(player.isIdle)

            Divider()

            Button(L("menu.step-forward", "Step Forward 5s")) {
                player.seek(relative: 5)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(player.isIdle)

            Button(L("menu.step-backward", "Step Backward 5s")) {
                player.seek(relative: -5)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(player.isIdle)

            Divider()

            Button(L("menu.next", "Next")) {
                player.playlistNext()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(player.playlist.count < 2)

            Button(L("menu.previous", "Previous")) {
                player.playlistPrevious()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(player.playlist.count < 2)

            Divider()

            Button(L("menu.next-chapter", "Next Chapter")) {
                player.nextChapter()
            }
            .disabled(player.chapters.isEmpty)

            Button(L("menu.previous-chapter", "Previous Chapter")) {
                player.previousChapter()
            }
            .disabled(player.chapters.isEmpty)

            Divider()

            Button(L("menu.frame-step", "Frame Step Forward")) {
                player.frameStepForward()
            }
            .keyboardShortcut(".", modifiers: [])
            .disabled(player.isIdle)

            Button(L("menu.frame-back-step", "Frame Step Backward")) {
                player.frameStepBackward()
            }
            .keyboardShortcut(",", modifiers: [])
            .disabled(player.isIdle)

            Divider()

            loopMenu
            abLoopMenu

            Divider()

            Button(L("menu.screenshot", "Screenshot")) {
                player.screenshot()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(player.isIdle)

            Divider()

            Button(L("menu.load-subtitle", "Load Subtitle File…")) {
                SubtitlePanel.present { url in
                    player.loadExternalSubtitle(url)
                }
            }
            .disabled(player.isIdle)

            if player.isRecording {
                Button(L("menu.stop-recording", "Stop Recording")) {
                    player.stopRecording()
                }
            } else {
                Button(L("menu.start-recording", "Record To File…")) {
                    player.startRecording()
                }
                .disabled(player.isIdle)
            }

            Button(L("menu.bookmark-add", "Add Bookmark")) {
                player.addBookmark()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(player.isIdle)

            Divider()

            Button(player.isMuted ? L("controls.unmute", "Unmute") : L("menu.mute", "Mute")) {
                player.isMuted.toggle()
            }
            .keyboardShortcut("m", modifiers: [])

            Button(L("menu.volume-up", "Volume Up")) {
                player.volume = min(player.volume + 5, 130)
            }
            .keyboardShortcut(.upArrow, modifiers: [])

            Button(L("menu.volume-down", "Volume Down")) {
                player.volume = max(player.volume - 5, 0)
            }
            .keyboardShortcut(.downArrow, modifiers: [])
        }

        CommandMenu(L("menu.video", "Video")) {
            aspectMenu
            rotateMenu
            cropMenu
            Divider()
            Toggle(isOn: Binding(
                get: { player.hdrEnabled },
                set: { player.hdrEnabled = $0 }
            )) {
                Text(L("video.hdr", "HDR Output"))
            }
            Toggle(isOn: Binding(
                get: { player.isOnTop },
                set: { player.isOnTop = $0 }
            )) {
                Text(L("menu.ontop", "Always on Top"))
            }
            Toggle(isOn: Binding(
                get: { player.isMiniWindow },
                set: { _ in player.toggleMiniWindow() }
            )) {
                Text(L("controls.pip", "Mini Window"))
            }
            Divider()
            Button(L("controls.fullscreen", "Toggle Full Screen")) {
                player.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }

        CommandMenu(L("menu.audio", "Audio")) {
            trackMenu(tracks: player.audioTracks, current: player.currentAudioTrack) { id in
                player.setAudioTrack(id)
            }
            if player.audioTracks.isEmpty {
                Text(L("panel.tracks.none", "No tracks")).foregroundStyle(.secondary)
            }
        }

        CommandMenu(L("menu.subtitle", "Subtitles")) {
            trackMenu(tracks: player.subtitleTracks, current: player.currentSubtitleTrack) { id in
                player.setSubtitleTrack(id)
            }
            if player.subtitleTracks.isEmpty {
                Text(L("panel.tracks.none", "No tracks")).foregroundStyle(.secondary)
            }
        }

        CommandMenu(L("panel.history", "History")) {
            let history = PlaybackStore.shared.history
            if history.isEmpty {
                Text(L("panel.history.empty", "No playback history yet")).foregroundStyle(.secondary)
            } else {
                ForEach(history.prefix(10)) { entry in
                    Button(entry.title) {
                        player.reopen(entry)
                    }
                }
                Divider()
                Button(L("panel.history.clear", "Clear History")) {
                    PlaybackStore.shared.clearHistory()
                }
            }
        }

        CommandMenu(L("menu.playlist", "Playlist")) {
            Button(L("panel.playlist.shuffle", "Shuffle")) {
                player.shufflePlaylist()
            }
            .disabled(player.playlist.count < 2)
            Button(L("panel.playlist.clear", "Clear")) {
                player.clearPlaylist()
            }
            .disabled(player.playlist.isEmpty)
        }
    }

    // MARK: - Submenus

    private var loopMenu: some View {
        Menu(L("menu.loop", "Loop")) {
            ForEach(LoopMode.allCases) { mode in
                Button {
                    player.setLoopMode(mode)
                } label: {
                    if player.loopMode == mode {
                        Text("\(loopLabel(mode)) ✓")
                    } else {
                        Text(loopLabel(mode))
                    }
                }
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

    private var abLoopMenu: some View {
        Menu(L("menu.ab-loop", "A-B Loop")) {
            Button(L("ab-loop.set-a", "Set Point A")) {
                player.setABLoopA()
            }
            .disabled(player.isIdle)
            Button(L("ab-loop.set-b", "Set Point B")) {
                player.setABLoopB()
            }
            .disabled(player.isIdle)
            Divider()
            Button(L("ab-loop.clear", "Clear A-B Loop")) {
                player.clearABLoop()
            }
            .disabled(player.abLoopA == nil && player.abLoopB == nil)
        }
    }

    @ViewBuilder
    private var aspectMenu: some View {
        Menu(L("video.aspect", "Aspect Ratio")) {
            aspectRow(L("video.aspect.fit", "Fit to Window"), mode: .fit)
            aspectRow(L("video.aspect.fill", "Fill Window"), mode: .fill)
            aspectRow(L("video.aspect.stretch", "Stretch to Window"), mode: .stretch)
            Divider()
            ForEach(["4:3", "16:9", "2.35:1", "1:1"], id: \.self) { ratio in
                Button {
                    AppSettings.shared.aspectMode = .custom
                    AppSettings.shared.aspectOverride = ratio
                    player.aspectMode = .custom
                    player.aspectOverride = ratio
                } label: {
                    if player.aspectMode == .custom && player.aspectOverride == ratio {
                        Text("\(ratio) ✓")
                    } else {
                        Text(ratio)
                    }
                }
            }
        }
    }

    private func aspectRow(_ label: String, mode: PlayerCore.AspectMode) -> some View {
        Button {
            AppSettings.shared.aspectMode = mode
            player.aspectMode = mode
        } label: {
            if player.aspectMode == mode {
                Text("\(label) ✓")
            } else {
                Text(label)
            }
        }
    }

    /// Rotation submenu: 0°/90°/180°/270° clockwise.
    private var rotateMenu: some View {
        Menu(L("video.rotate", "Rotation")) {
            ForEach([0, 90, 180, 270], id: \.self) { degrees in
                Button("\(degrees)°") {
                    player.videoRotation = degrees
                }
            }
        }
    }

    /// Crop submenu: off, centered ratio presets, custom margins.
    private var cropMenu: some View {
        Menu(L("video.crop", "Crop")) {
            Button(L("video.crop.off", "Off")) {
                player.cropMode = .off
            }
            Divider()
            ForEach(["4:3", "16:9", "2.35:1", "1:1"], id: \.self) { ratio in
                Button(ratio) {
                    player.setCropRatio(ratio)
                }
            }
            Divider()
            Button(L("video.crop.custom", "Custom")) {
                player.cropMode = .custom
            }
        }
    }

    /// A dynamic track list with an "Off" entry, used by the Audio and Subtitles menus.
    private func trackMenu(tracks: [TrackInfo], current: Int?, action: @escaping (Int?) -> Void) -> some View {
        Group {
            Button(L("panel.tracks.off", "Off")) {
                action(nil)
            }
            if current != nil { Divider() }
            ForEach(tracks) { track in
                Button {
                    action(track.id)
                } label: {
                    if track.id == current {
                        Text("\(track.label) ✓")
                    } else {
                        Text(track.label)
                    }
                }
            }
        }
    }
}
