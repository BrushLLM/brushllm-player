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
                PlaybackProgressView(player: player, timeline: player.timeline)
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
            PlaybackProgressView(player: player, timeline: player.timeline, compact: true)
            muteButton
            PlayerIconButton(icon: "pip.exit", help: L("controls.pip-exit", "Exit Mini Window"),
                             active: true) {
                player.toggleMiniWindow()
            }
            PlayerIconButton(icon: "arrow.up.left.and.arrow.down.right",
                             help: L("controls.fullscreen", "Toggle Full Screen")) {
                player.toggleFullscreen()
            }
        }
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
                PlayerIconButton(icon: "folder", help: L("menu.open", "Open…")) {
                    OpenMediaPanel.present { urls in player.open(urls) }
                }
                PlayerIconButton(icon: "backward.end.fill", help: L("menu.previous", "Previous"),
                                  disabled: player.playlist.count < 2) {
                    player.playlistPrevious()
                }
                playPauseButton
                PlayerIconButton(icon: "forward.end.fill", help: L("menu.next", "Next"),
                                  disabled: player.playlist.count < 2) {
                    player.playlistNext()
                }
                PlayerIconButton(icon: "stop.fill", help: L("menu.stop", "Stop"), disabled: player.isIdle) {
                    player.stop()
                }
                if !player.chapters.isEmpty {
                    PlayerIconButton(icon: "backward.end.fill.tv", help: L("menu.previous-chapter", "Previous Chapter")) {
                        player.previousChapter()
                    }
                    PlayerIconButton(icon: "forward.end.fill.tv", help: L("menu.next-chapter", "Next Chapter")) {
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
            PlayerIconButton(icon: "camera.fill", help: L("menu.screenshot", "Screenshot"),
                             disabled: player.isIdle) {
                player.screenshot()
            }
            abLoopButton
        }
        volumeControl
        PlayerIconButton(icon: "list.bullet", help: L("controls.playlist", "Playlist"),
                         active: isPlaylistVisible) {
            togglePlaylist()
        }
        // Window control group: on-top / mini / fullscreen.
        windowGroupDivider
        onTopButton
        PlayerIconButton(icon: "pip.enter", help: L("controls.pip", "Mini Window"),
                          active: player.isMiniWindow) {
            player.toggleMiniWindow()
        }
        PlayerIconButton(icon: "arrow.up.left.and.arrow.down.right",
                         help: L("controls.fullscreen", "Toggle Full Screen")) {
            player.toggleFullscreen()
        }
    }

    /// Network settings — opens the WebDAV browser / network panel
    /// (server management, playback and the User-Agent setting).
    private var networkButton: some View {
        PlayerIconButton(icon: "network", help: L("controls.network", "Network")) {
            NotificationCenter.default.post(name: .brushPlayerShowWebDAV, object: nil)
        }
    }

    /// Thin separator marking the window-control group at the far right.
    private var windowGroupDivider: some View {
        Rectangle()
            .fill(BrushLLMPlayerTheme.controlSeparator)
            .frame(width: 0.5, height: 14)
            .padding(.horizontal, 4)
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlay()
        } label: {
            Image(systemName: (player.isIdle || player.isPaused) ? "play.fill" : "pause.fill")
                .font(.system(size: DesignIcon.play, weight: .semibold))
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .frame(width: 32, height: 28)
                .background {
                    // Neutral emphasis: white fill marks the continuous
                    // chrome language; the accent is reserved for selection.
                    RoundedRectangle(cornerRadius: DesignRadius.row)
                        .fill(Color.white.opacity(0.12))
                }
        }
        .buttonStyle(PressedDimButtonStyle())
        .disabled(player.isIdle && player.playlist.isEmpty)
        .opacity(player.isIdle && player.playlist.isEmpty ? BrushLLMPlayerTheme.disabledOpacity : 1)
        .help((player.isIdle || player.isPaused) ? L("controls.play", "Play") : L("controls.pause", "Pause"))
        .accessibilityLabel((player.isIdle || player.isPaused) ? L("controls.play", "Play") : L("controls.pause", "Pause"))
    }

    // MARK: - Right-side tools

    /// Speed popover visibility (IINA's 0.25–16× speedSlider experience).
    @State private var speedPanelVisible = false

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
            Button {
                speedPanelVisible.toggle()
            } label: {
                label
            }
            .buttonStyle(PressedDimButtonStyle())
            .popover(isPresented: $speedPanelVisible, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Slider(value: Binding(
                        get: { player.speed },
                        set: { player.speed = (($0 / 0.05).rounded() * 0.05) }
                    ), in: 0.25...16)
                        .tint(BrushLLMPlayerTheme.accent)
                        .frame(width: 180)
                    HStack {
                        Text(String(format: "%.2g×", player.speed))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(BrushLLMPlayerTheme.accent)
                        Spacer()
                        Button(L("video.delay-reset", "Reset")) {
                            player.speed = 1
                        }
                        .font(.caption)
                        .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                        .buttonStyle(PressedDimButtonStyle())
                    }
                    Divider().overlay(BrushLLMPlayerTheme.controlSeparator)
                    // Preset chips.
                    HStack(spacing: 6) {
                        ForEach(speedOptions, id: \.self) { option in
                            Button {
                                player.speed = option
                            } label: {
                                Text("\(formatSpeed(option))×")
                                    .font(.system(size: 10, weight: player.speed == option ? .bold : .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(player.speed == option ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlTextSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background {
                                        if player.speed == option {
                                            Capsule().fill(BrushLLMPlayerTheme.accent)
                                        }
                                    }
                            }
                            .buttonStyle(PressedDimButtonStyle())
                        }
                    }
                }
                .padding(12)
                .frame(minWidth: 220)
                .presentationBackground(BrushLLMPlayerTheme.panelMaterial)
            }
            .help(L("controls.speed", "Playback speed"))
            .accessibilityLabel(L("controls.speed", "Playback speed"))
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
        .buttonStyle(PressedDimButtonStyle())
        .help(L("panel.tracks.subtitle", "Subtitles"))
        .accessibilityLabel(L("panel.tracks.subtitle", "Subtitles"))
        .popover(isPresented: $subtitlePanelVisible, arrowEdge: .bottom) {
            TrackPanel(player: player, initialSection: .subtitle)
        }
    .presentationBackground(BrushLLMPlayerTheme.panelMaterial)
    }

    /// Audio track picker — the headphones icon.
    private var audioTrackButton: some View {
        Button {
            audioPanelVisible.toggle()
        } label: {
            Image(systemName: "headphones")
                .font(.system(size: DesignIcon.toolbar, weight: .medium))
                .foregroundStyle(player.currentAudioTrack != nil ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(PressedDimButtonStyle())
        .help(L("panel.tracks.audio", "Audio"))
        .accessibilityLabel(L("panel.tracks.audio", "Audio"))
        .popover(isPresented: $audioPanelVisible, arrowEdge: .bottom) {
            TrackPanel(player: player, initialSection: .audio)
        }
    .presentationBackground(BrushLLMPlayerTheme.panelMaterial)
    }

    /// A-B loop: quick menu to set point A, point B, or clear. The text label
    /// "A⇄B" reads unambiguously (the old a-square icon was confusable with
    /// the subtitle button).
    @ViewBuilder
    private var abLoopButton: some View {
        let label = Text("A⇄B")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(player.abLoopA != nil || player.abLoopB != nil ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
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
            .accessibilityLabel(L("menu.ab-loop", "A-B Loop"))
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
                .font(.system(size: DesignIcon.toolbar, weight: .medium))
                .foregroundStyle(videoPanelVisible || player.aspectMode != .fit
                                 || player.isCropActive || player.videoRotation != 0
                                 || player.hdrEnabled
                                 ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(PressedDimButtonStyle())
        .help(L("controls.video-settings", "Video settings"))
        .accessibilityLabel(L("controls.video-settings", "Video settings"))
        .popover(isPresented: $videoPanelVisible, arrowEdge: .bottom) {
            VideoSettingsPanel(player: player)
        }
    .presentationBackground(BrushLLMPlayerTheme.panelMaterial)
    }

    /// Audio effects popover — equalizer and A/V sync delay adjustment.
    private var audioEffectsButton: some View {
        Button {
            audioEffectsPanelVisible.toggle()
        } label: {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: DesignIcon.toolbar, weight: .medium))
                .foregroundStyle(player.eqEnabled || player.audioDelay != 0 || player.videoDelay != 0
                                 ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(PressedDimButtonStyle())
        .help(L("controls.audio-effects", "Audio Effects"))
        .accessibilityLabel(L("controls.audio-effects", "Audio Effects"))
        .popover(isPresented: $audioEffectsPanelVisible, arrowEdge: .bottom) {
            AudioEffectsPanel(player: player)
        }
    .presentationBackground(BrushLLMPlayerTheme.panelMaterial)
    }

    /// Always-on-top toggle (window control group).
    private var onTopButton: some View {
        PlayerIconButton(icon: player.isOnTop ? "pin.fill" : "pin",
                         help: L("video.ontop", "Always on Top"),
                         active: player.isOnTop) {
            player.isOnTop.toggle()
        }
    }

    /// Mute toggle.
    private var muteButton: some View {
        PlayerIconButton(icon: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                         iconSize: 12, width: 24,
                         help: player.isMuted ? L("controls.unmute", "Unmute") : L("controls.mute", "Mute")) {
            player.isMuted.toggle()
        }
    }

    /// Mute button + compact custom slider with a small knob.
    private var volumeControl: some View {
        HStack(spacing: 4) {
            muteButton
            VolumeSlider(value: $player.volume, range: 0...130)
                .frame(width: 72)
                .help(L("controls.volume", "Volume"))
                .accessibilityLabel(L("controls.volume", "Volume"))
        }
    }

    // MARK: - Formatting

    private func formatSpeed(_ speed: Double) -> String {
        speed == speed.rounded() ? String(Int(speed)) : String(speed)
    }
}
