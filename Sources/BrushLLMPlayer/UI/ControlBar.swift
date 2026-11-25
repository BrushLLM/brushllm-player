import SwiftUI

/// Arranges the same transport and timeline for each viewing mode.
struct ControlBar: View {
    @ObservedObject var player: PlayerCore
    let showChapters: () -> Void
    @State private var speedOpen = false
    @State private var toolsExpanded = false

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
        VStack(spacing: 10) {
            fullscreenToolsButton
            let layout = toolsExpanded ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
            layout {
                playPauseButton
                fullscreenSpeedButton
                muteButton
            }
            .frame(maxWidth: .infinity, alignment: toolsExpanded ? .leading : .center)

            if toolsExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        progress(compact: true)
                        Divider()
                        PlaybackTools(player: player, showChapters: showChapters, fullscreen: true)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Spacer(minLength: 0)
            }

            fullscreenButton
                .frame(maxWidth: .infinity, alignment: toolsExpanded ? .leading : .center)
        }
        .padding(8)
        .frame(width: toolsExpanded ? 224 : 64)
        .frame(maxHeight: .infinity)
        .background(BrushLLMPlayerTheme.viewingSurface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(BrushLLMPlayerTheme.controlSeparator).frame(width: 1)
        }
    }

    private var fullscreenToolsButton: some View {
        Button {
            toolsExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: toolsExpanded ? "chevron.left" : "chevron.right")
                if toolsExpanded { Text(L("player.options", "Playback options")).lineLimit(1) }
            }
            .frame(minWidth: 32, minHeight: 28)
        }
        .controlSize(.small)
        .help(L("player.options", "Playback options"))
        .accessibilityLabel(L("player.options", "Playback options"))
        .accessibilityAddTraits(toolsExpanded ? .isSelected : [])
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
            .popover(isPresented: $speedOpen, arrowEdge: .trailing) {
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
