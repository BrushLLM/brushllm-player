import SwiftUI

/// Arranges the same transport and timeline for each viewing mode.
struct ControlBar: View {
    @ObservedObject var player: PlayerCore
    let showChapters: () -> Void
    let hideFullscreenControls: () -> Void
    @State private var speedOpen = false

    var body: some View {
        Group {
            if player.isFullscreen {
                fullscreenControls
            } else {
                Group {
                    if player.isMiniWindow {
                        miniControls
                    } else {
                        VStack(spacing: 4) {
                            progress(compact: false)
                            transport
                            Divider().padding(.vertical, 2)
                            PlaybackTools(player: player, showChapters: showChapters)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(player.isMiniWindow ? BrushLLMPlayerTheme.viewingSurface : BrushLLMPlayerTheme.window)
            }
        }
    }

    private var miniControls: some View {
        HStack(spacing: 8) {
            playPauseButton
            progress(compact: true)
            muteButton
            miniButton
            fullscreenButton
        }
    }

    private var fullscreenControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                playPauseButton
                progress(compact: true)
                fullscreenSpeedButton
                muteButton
                fullscreenButton
                fullscreenToolsButton
            }
            Divider()
            PlaybackTools(player: player, showChapters: showChapters, fullscreen: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(BrushLLMPlayerTheme.viewingSurface)
    }

    private var fullscreenToolsButton: some View {
        PlayerIconButton(icon: "chevron.down", help: L("player.options", "Playback options"),
                         action: hideFullscreenControls)
    }

    private var fullscreenSpeedButton: some View {
        let title = L("controls.speed", "Playback speed")
        let rate = PlaybackSpeedPanel.label(player.speed)
        return Button(rate) { speedOpen.toggle() }
            .controlSize(.small)
            .monospacedDigit()
            .help(title)
            .accessibilityLabel(title)
            .accessibilityValue(rate)
            .popover(isPresented: $speedOpen, arrowEdge: .bottom) {
                PlaybackSpeedPanel(player: player)
                    .presentationBackground(BrushLLMPlayerTheme.panelMaterial)
            }
            .onDisappear { speedOpen = false }
    }

    private func progress(compact: Bool) -> some View {
        PlaybackProgressView(player: player, timeline: player.timeline, compact: compact)
            .id(player.loadGeneration)
    }

    private var transport: some View {
        HStack(spacing: 4) {
            PlayerIconButton(icon: "backward.end", help: L("menu.previous", "Previous"),
                             disabled: player.playlist.count < 2, action: player.playlistPrevious)
            playPauseButton
            PlayerIconButton(icon: "forward.end", help: L("menu.next", "Next"),
                             disabled: player.playlist.count < 2, action: player.playlistNext)
            PlayerIconButton(icon: "stop", help: L("menu.stop", "Stop"),
                             disabled: player.isIdle, action: player.stop)
            Spacer(minLength: 4)
            muteButton
            ViewThatFits(in: .horizontal) {
                VolumeSlider(value: $player.volume, range: 0...130)
                    .frame(width: 68)
                EmptyView()
            }
            Rectangle()
                .fill(BrushLLMPlayerTheme.controlSeparator)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)
            miniButton
            fullscreenButton
        }
    }

    private var playPauseButton: some View {
        let paused = player.isIdle || player.isPaused
        let title = paused ? L("controls.play", "Play") : L("controls.pause", "Pause")
        return Button(action: player.togglePlay) {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 38, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(TransportPlayButtonStyle())
        .disabled(player.isIdle && player.playlist.isEmpty)
        .help(title)
        .accessibilityLabel(title)
    }

    private var muteButton: some View {
        PlayerIconButton(icon: player.isMuted ? "speaker.slash" : "speaker.wave.2",
                         help: player.isMuted ? L("controls.unmute", "Unmute") : L("controls.mute", "Mute")) {
            player.isMuted.toggle()
        }
    }

    private var miniButton: some View {
        let title = player.isMiniWindow ? L("controls.pip-exit", "Exit Mini Window") : L("controls.pip", "Mini Window")
        return PlayerIconButton(icon: player.isMiniWindow ? "pip.exit" : "pip.enter",
                                help: title, action: player.toggleMiniWindow)
    }

    private var fullscreenButton: some View {
        let title = player.isFullscreen ? L("player.fullscreen-exit", "Exit full screen")
            : L("controls.fullscreen", "Toggle Full Screen")
        return PlayerIconButton(icon: player.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                help: title, action: player.toggleFullscreen)
    }
}

private struct TransportPlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlTextSecondary)
            .background {
                RoundedRectangle(cornerRadius: DesignRadius.row)
                    .fill(isEnabled ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.hoverFill)
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: DesignRadius.card)
                        .strokeBorder(BrushLLMPlayerTheme.accentText, lineWidth: 2)
                        .padding(-3)
                }
            }
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}
