import SwiftUI

/// PotPlayer-style persistent control bar.
///
/// Layout (three sections):
/// - Row 1: full-width progress bar with chapter/A-B markers and a hover
///   thumbnail preview that follows the pointer.
/// - Row 2: left = playback controls + time; middle = flexible space;
///   right = tool buttons, right-aligned in a fixed order.
///
/// All small icons share one size (13pt symbol in a 28×28 hit target) so the
/// row reads evenly.
struct ControlBar: View {
    @ObservedObject var player: PlayerCore
    var togglePlaylist: () -> Void
    var isPlaylistVisible: Bool
    /// True while rendering the static live-resize snapshot. ImageRenderer
    /// cannot render Menu views offscreen — they come out as placeholder
    /// artifacts (a yellow box with a red glyph) that covered the speed and
    /// A-B buttons during resizes. In snapshot mode the two Menus render as
    /// their plain text labels, which are visually identical to their
    /// borderless live appearance.
    var forSnapshot: Bool = false

    /// Local scrub position while dragging the progress bar.
    @State private var scrubPosition: Double = 0

    /// Hover preview: time + horizontal fraction (0…1) on the progress bar.
    @State private var hoverPreview: (time: Double, fraction: CGFloat)?

    /// Popover visibility.
    @State private var subtitlePanelVisible = false
    @State private var audioPanelVisible = false
    @State private var videoPanelVisible = false
    @State private var audioEffectsPanelVisible = false

    private let speedOptions: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: 4) {
            if player.isMiniWindow {
                miniBar
            } else {
                progressRow
                buttonRow
            }
        }
        .padding(.horizontal, player.isMiniWindow ? 8 : 12)
        .padding(.vertical, 6)
        .background(BrushLLMPlayerTheme.barMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BrushLLMPlayerTheme.controlSeparator)
                .frame(height: 0.5)
        }
    }

    /// Compact bar for the mini window: play/pause, progress, volume,
    /// exit-mini and fullscreen only.
    private var miniBar: some View {
        HStack(spacing: 6) {
            playPauseButton
            Text(formatTime(player.position))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .lineLimit(1)
                .fixedSize()
            ProgressBar(
                position: player.position,
                duration: player.duration,
                chapters: player.chapters,
                abLoopA: player.abLoopA,
                abLoopB: player.abLoopB,
                bookmarks: player.currentFileBookmarks,
                onScrub: { value in
                    player.isScrubbing = true
                    scrubPosition = value
                },
                onScrubEnded: { value in
                    player.isScrubbing = false
                    player.seek(to: value)
                }
            )
            Text(formatTime(player.duration))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .lineLimit(1)
                .fixedSize()
            muteButton
            iconButton("pip.exit", help: L("controls.pip-exit", "Exit Mini Window"),
                       active: true) {
                player.toggleMiniWindow()
            }
            iconButton("arrow.up.left.and.arrow.down.right",
                       help: L("controls.fullscreen", "Toggle Full Screen")) {
                player.toggleFullscreen()
            }
        }
    }

    // MARK: - Row 1: progress

    /// Fixed preview card metrics: image 160×90 + time label ≈ 108pt tall.
    private static let previewCardWidth: CGFloat = 160
    private static let previewCardImageHeight: CGFloat = 90
    private static let previewCardTotalHeight: CGFloat = 108

    private var progressRow: some View {
        HStack(spacing: 10) {
            // Time labels: never wrap, fixed single-line.
            Text(formatTime(player.position))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 44, alignment: .trailing)

            ProgressBar(
                position: player.position,
                duration: player.duration,
                chapters: player.chapters,
                abLoopA: player.abLoopA,
                abLoopB: player.abLoopB,
                bookmarks: player.currentFileBookmarks,
                onScrub: { value in
                    player.isScrubbing = true
                    scrubPosition = value
                },
                onScrubEnded: { value in
                    player.isScrubbing = false
                    player.seek(to: value)
                },
                onHover: { fraction, time in
                    if let fraction, let time {
                        hoverPreview = (time, fraction)
                    } else {
                        hoverPreview = nil
                    }
                }
            )
            .frame(height: 18)
            .overlay(alignment: .topLeading) {
                // The preview floats fully above the bar: fixed size, never
                // squashed by the 18pt track, clamped to the bar's width.
                if let preview = hoverPreview, player.duration > 0 {
                    GeometryReader { geometry in
                        let barWidth = geometry.size.width
                        hoverPreviewView(preview)
                            .fixedSize()
                            .offset(x: previewX(preview.fraction, barWidth: barWidth),
                                    y: -Self.previewCardTotalHeight - 6)
                    }
                    .allowsHitTesting(false)
                }
            }

            Text(formatTime(player.duration))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 44, alignment: .leading)
        }
    }

    /// The floating preview card: fixed 160×90 thumbnail (cover) + time label.
    private func hoverPreviewView(_ preview: (time: Double, fraction: CGFloat)) -> some View {
        VStack(spacing: 3) {
            Group {
                if let image = player.thumbnail(at: preview.time) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.black.opacity(0.75))
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
            .frame(width: Self.previewCardWidth, height: Self.previewCardImageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(BrushLLMPlayerTheme.controlSeparator, lineWidth: 0.5)
            }
            Text(formatTime(preview.time))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.55), radius: 6)
        .allowsHitTesting(false)
    }

    /// The preview card's leading-x so its center tracks the pointer, clamped
    /// so the card never leaves the bar area.
    private func previewX(_ fraction: CGFloat, barWidth: CGFloat) -> CGFloat {
        let cardWidth = Self.previewCardWidth
        let ideal = fraction * barWidth - cardWidth / 2
        return min(max(ideal, 2), max(barWidth - cardWidth - 2, 2))
    }

    // MARK: - Row 2: buttons (left / flex / right)

    private var buttonRow: some View {
        HStack(spacing: 0) {
            // LEFT: playback controls. fixedSize freezes the group's
            // measurement: its content is all fixed-size buttons, so the
            // measurement no longer re-runs on every resize proposal
            // (live-resize layout cost is dominated by re-measuring this
            // bar's ~25 buttons per tick).
            HStack(spacing: 2) {
                iconButton("folder", help: L("menu.open", "Open…")) {
                    OpenMediaPanel.present { urls in player.open(urls) }
                }
                iconButton("backward.end.fill", help: L("menu.previous", "Previous"),
                           disabled: player.playlist.count < 2) {
                    player.playlistPrevious()
                }
                playPauseButton
                iconButton("forward.end.fill", help: L("menu.next", "Next"),
                           disabled: player.playlist.count < 2) {
                    player.playlistNext()
                }
                iconButton("stop.fill", help: L("menu.stop", "Stop"), disabled: player.isIdle) {
                    player.stop()
                }
                if !player.chapters.isEmpty {
                    iconButton("backward.end.fill.tv", help: L("menu.previous-chapter", "Previous Chapter")) {
                        player.previousChapter()
                    }
                    iconButton("forward.end.fill.tv", help: L("menu.next-chapter", "Next Chapter")) {
                        player.nextChapter()
                    }
                }
            }
            .fixedSize()

            // MIDDLE: flexible space
            Spacer(minLength: 12)

            // RIGHT: tools & system controls. Low-frequency settings live
            // behind the picture-settings and audio-effects buttons; the
            // window controls (on-top / mini / fullscreen) form a separate
            // group at the far right. ViewThatFits drops the secondary tools
            // when the window is too narrow for the full set. fixedSize on
            // both alternatives makes their measurements proposal-
            // independent, so the fit check reads cached sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) {
                    rightTools(includeSecondary: true)
                }
                .fixedSize()
                HStack(spacing: 2) {
                    rightTools(includeSecondary: false)
                }
                .fixedSize()
            }
        }
    }

    /// The right-side tool cluster. `includeSecondary` keeps the full set;
    /// the compact variant prioritizes the primary tools.
    @ViewBuilder
    private func rightTools(includeSecondary: Bool) -> some View {
        speedMenu
        subtitleTrackButton
        audioTrackButton
        networkButton
        videoSettingsButton
        audioEffectsButton
        if includeSecondary {
            iconButton("camera.fill", help: L("menu.screenshot", "Screenshot"),
                       disabled: player.isIdle) {
                player.screenshot()
            }
            abLoopButton
        }
        volumeControl
        iconButton("list.bullet", help: L("controls.playlist", "Playlist"),
                   active: isPlaylistVisible) {
            togglePlaylist()
        }
        // Window control group: on-top / mini / fullscreen.
        windowGroupDivider
        onTopButton
        iconButton("pip.enter", help: L("controls.pip", "Mini Window"),
                   active: player.isMiniWindow) {
            player.toggleMiniWindow()
        }
        iconButton("arrow.up.left.and.arrow.down.right",
                   help: L("controls.fullscreen", "Toggle Full Screen")) {
            player.toggleFullscreen()
        }
    }

    /// Network settings — opens the WebDAV browser / network panel
    /// (server management, playback and the User-Agent setting).
    private var networkButton: some View {
        Button {
            NotificationCenter.default.post(name: .brushPlayerShowWebDAV, object: nil)
        } label: {
            Image(systemName: "network")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(L("controls.network", "Network"))
    }

    /// Thin separator marking the window-control group at the far right.
    private var windowGroupDivider: some View {
        Rectangle()
            .fill(BrushLLMPlayerTheme.controlSeparator)
            .frame(width: 0.5, height: 14)
            .padding(.horizontal, 4)
    }

    // MARK: - Standard icon button

    /// One size for every small icon: 13pt symbol inside a 28×28 hit target.
    private func iconButton(_ icon: String, help: String, active: Bool = false,
                            disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlay()
        } label: {
            Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 15, weight: .semibold))
                // Brand violet fill with the light glyph (kept distinct from
                // the lemon accent used for selections).
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .frame(width: 32, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(BrushPalette.violet.opacity(player.isPaused ? 0.85 : 0.3))
                }
        }
        .buttonStyle(.plain)
        .disabled(player.isIdle && player.playlist.isEmpty)
        .help(player.isPaused ? L("controls.play", "Play") : L("controls.pause", "Pause"))
    }

    // MARK: - Right-side tools

    @ViewBuilder
    private var speedMenu: some View {
        let label = Text("\(formatSpeed(player.speed))×")
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(player.speed == 1 ? BrushLLMPlayerTheme.controlTextSecondary : BrushLLMPlayerTheme.accent)
            .frame(width: 40, height: 28)
            .contentShape(.rect)
        if forSnapshot {
            label.fixedSize()
        } else {
            Menu {
                ForEach(speedOptions, id: \.self) { option in
                    Button {
                        player.speed = option
                    } label: {
                        Text("\(formatSpeed(option))×")
                    }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("controls.speed", "Playback speed"))
        }
    }

    /// Subtitle track picker — the CC icon.
    private var subtitleTrackButton: some View {
        Button {
            subtitlePanelVisible.toggle()
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(player.currentSubtitleTrack != nil ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(L("panel.tracks.subtitle", "Subtitles"))
        .popover(isPresented: $subtitlePanelVisible, arrowEdge: .bottom) {
            TrackPanel(player: player, initialSection: .subtitle)
        }
    }

    /// Audio track picker — the headphones icon.
    private var audioTrackButton: some View {
        Button {
            audioPanelVisible.toggle()
        } label: {
            Image(systemName: "headphones")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(player.currentAudioTrack != nil ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(L("panel.tracks.audio", "Audio"))
        .popover(isPresented: $audioPanelVisible, arrowEdge: .bottom) {
            TrackPanel(player: player, initialSection: .audio)
        }
    }

    /// A-B loop: quick menu to set point A, point B, or clear. The text label
    /// "A⇄B" reads unambiguously (the old a-square icon was confusable with
    /// the subtitle button).
    @ViewBuilder
    private var abLoopButton: some View {
        let label = Text("A⇄B")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(player.abLoopA != nil || player.abLoopB != nil ? BrushPalette.orange : BrushLLMPlayerTheme.controlTextSecondary)
            .frame(width: 36, height: 28)
            .contentShape(.rect)
        if forSnapshot {
            label.fixedSize()
        } else {
            Menu {
                Button(L("ab-loop.set-a", "Set Point A")) { player.setABLoopA() }
                    .disabled(player.isIdle)
                Button(L("ab-loop.set-b", "Set Point B")) { player.setABLoopB() }
                    .disabled(player.isIdle)
                Divider()
                Button(L("ab-loop.clear", "Clear A-B Loop")) { player.clearABLoop() }
                    .disabled(player.abLoopA == nil && player.abLoopB == nil)
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("menu.ab-loop", "A-B Loop"))
        }
    }

    // MARK: - Settings panels & window controls

    /// Picture settings popover — aspect ratio, rotation, crop, HDR and
    /// hardware decoding collected behind one button.
    private var videoSettingsButton: some View {
        Button {
            videoPanelVisible.toggle()
        } label: {
            Image(systemName: "tv")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(videoPanelVisible || player.aspectMode != .fit
                                 || player.isCropActive || player.videoRotation != 0
                                 || player.hdrEnabled
                                 ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(L("controls.video-settings", "Video settings"))
        .popover(isPresented: $videoPanelVisible, arrowEdge: .bottom) {
            VideoSettingsPanel(player: player)
        }
    }

    /// Audio effects popover — equalizer and A/V sync delay adjustment.
    private var audioEffectsButton: some View {
        Button {
            audioEffectsPanelVisible.toggle()
        } label: {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(player.eqEnabled || player.audioDelay != 0 || player.videoDelay != 0
                                 ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(L("controls.audio-effects", "Audio Effects"))
        .popover(isPresented: $audioEffectsPanelVisible, arrowEdge: .bottom) {
            AudioEffectsPanel(player: player)
        }
    }

    /// Always-on-top toggle (window control group).
    private var onTopButton: some View {
        Button {
            player.isOnTop.toggle()
        } label: {
            Image(systemName: player.isOnTop ? "pin.fill" : "pin")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(player.isOnTop ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(L("video.ontop", "Always on Top"))
    }

    /// Mute toggle.
    private var muteButton: some View {
        Button {
            player.isMuted.toggle()
        } label: {
            Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 24, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(player.isMuted ? L("controls.unmute", "Unmute") : L("controls.mute", "Mute"))
    }

    /// Mute button + compact custom slider with a small knob.
    private var volumeControl: some View {
        HStack(spacing: 4) {
            muteButton
            VolumeSlider(value: $player.volume, range: 0...130)
                .frame(width: 62)
                .help(L("controls.volume", "Volume"))
        }
    }

    // MARK: - Formatting

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func formatSpeed(_ speed: Double) -> String {
        speed == speed.rounded() ? String(Int(speed)) : String(speed)
    }
}
