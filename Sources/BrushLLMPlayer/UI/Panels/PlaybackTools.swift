import SwiftUI

struct PlaybackTools: View {
    @ObservedObject var player: PlayerCore
    let showChapters: () -> Void
    var fullscreen = false

    @State private var selected: Panel?

    private enum Panel {
        case speed, audio, subtitles, video, effects, chapters, loop
    }

    var body: some View {
        WrappingRows() {
            if !fullscreen {
                panelButton(.speed, icon: "gauge.medium", title: L("controls.speed", "Playback speed")) {
                    PlaybackSpeedPanel(player: player)
                }
            }
            panelButton(.audio, icon: "headphones", title: L("panel.tracks.audio", "Audio")) {
                TrackPanel(player: player, initialSection: .audio)
            }
            panelButton(.subtitles, icon: "captions.bubble", title: L("panel.tracks.subtitle", "Subtitles")) {
                TrackPanel(player: player, initialSection: .subtitle)
            }
            panelButton(.video, icon: "slider.horizontal.3", title: L("controls.video-settings", "Video settings")) {
                VideoSettingsPanel(player: player)
            }
            panelButton(.effects, icon: "waveform", title: L("controls.audio-effects", "Audio Effects")) {
                AudioEffectsPanel(player: player)
            }
            if fullscreen {
                panelButton(.chapters, icon: "list.bullet", title: L("panel.chapters", "Chapters")) {
                    PlayerLibraryPanel(player: player, section: .chapters)
                        .frame(width: 260, height: 220)
                }
            } else {
                toolButton(icon: "list.bullet", title: L("panel.chapters", "Chapters"), action: showChapters)
            }
            toolButton(icon: "camera", title: L("menu.screenshot", "Screenshot"), action: player.screenshot)
                .disabled(player.isIdle)
                .opacity(player.isIdle ? BrushLLMPlayerTheme.disabledOpacity : 1)
            panelButton(.loop, icon: "repeat", title: L("menu.ab-loop", "A-B Loop"), active: hasLoop) {
                VStack(alignment: .leading, spacing: 8) {
                    Button(L("ab-loop.set-a", "Set Point A"), action: player.setABLoopA).disabled(player.isIdle)
                    Button(L("ab-loop.set-b", "Set Point B"), action: player.setABLoopB).disabled(player.isIdle)
                    Button(L("ab-loop.clear", "Clear A-B Loop"), action: player.clearABLoop).disabled(!hasLoop)
                }
                .padding(12)
            }
            toolButton(icon: "pin", title: L("video.ontop", "Always on Top"), active: player.isOnTop) {
                player.isOnTop.toggle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("player.options", "Playback options"))
    }

    private var hasLoop: Bool { player.abLoopA != nil || player.abLoopB != nil }

    private func panelButton<Contents: View>(
        _ panel: Panel, icon: String, title: String, active: Bool = false,
        @ViewBuilder contents: @escaping () -> Contents
    ) -> some View {
        toolButton(icon: icon, title: title, active: selected == panel || active) {
            selected = selected == panel ? nil : panel
        }
        .popover(isPresented: Binding(
            get: { selected == panel },
            set: { if !$0 && selected == panel { selected = nil } }
        ), arrowEdge: fullscreen ? .trailing : .bottom) {
            contents()
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .presentationBackground(BrushLLMPlayerTheme.panelMaterial)
        }
    }

    private func toolButton(icon: String, title: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { label(icon: icon, title: title, active: active) }
            .buttonStyle(PressedDimButtonStyle())
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func label(icon: String, title: String, active: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? BrushLLMPlayerTheme.accentText : BrushLLMPlayerTheme.controlText)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(active ? BrushLLMPlayerTheme.selectionFill : BrushLLMPlayerTheme.hoverFill,
                        in: .rect(cornerRadius: DesignRadius.row))
            .contentShape(.rect)
    }
}

struct PlaybackSpeedPanel: View {
    @ObservedObject var player: PlayerCore

    private static let presets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    static func rates(including speed: Double) -> [Double] {
        presets.contains(speed) ? presets : (presets + [speed]).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("controls.speed", "Playback speed"))
                .font(.headline)
            Slider(value: Binding(
                get: { player.speed },
                set: { player.speed = (($0 / 0.05).rounded() * 0.05) }
            ), in: 0.25...16)
            .tint(BrushLLMPlayerTheme.accent)
            .accessibilityLabel(L("controls.speed", "Playback speed"))
            HStack {
                Text(Self.label(player.speed))
                    .monospacedDigit()
                    .foregroundStyle(BrushLLMPlayerTheme.accentText)
                Spacer()
                Button(L("video.delay-reset", "Reset")) { player.speed = 1 }
            }
            Divider()
            HStack(spacing: 4) {
                ForEach(Self.presets, id: \.self) { option in
                    Button(Self.label(option)) { player.speed = option }
                        .accessibilityAddTraits(player.speed == option ? .isSelected : [])
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(minWidth: 228)
        .foregroundStyle(BrushLLMPlayerTheme.controlText)
    }

    static func label(_ speed: Double) -> String {
        "\(speed.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}
