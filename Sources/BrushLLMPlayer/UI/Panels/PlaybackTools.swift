import SwiftUI

/// Playback options that are useful but do not need their own transport button.
struct PlaybackTools: View {
    @ObservedObject var player: PlayerCore
    let showChapters: () -> Void

    @State private var visible = false
    @State private var section: Section = .options

    private enum Section {
        case options, speed, audio, subtitles, video, effects
    }

    var body: some View {
        PlayerIconButton(icon: "ellipsis", help: L("player.options", "Playback options"), active: visible) {
            section = .options
            visible.toggle()
        }
        .popover(isPresented: $visible, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                if section != .options {
                    HStack {
                        Button {
                            section = .options
                        } label: {
                            Label(L("player.options", "Playback options"), systemImage: "chevron.left")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(12)
                    Divider()
                }
                panel
            }
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .presentationBackground(BrushLLMPlayerTheme.panelMaterial)
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch section {
        case .options:
            options
        case .speed:
            speed
        case .audio:
            TrackPanel(player: player, initialSection: .audio)
        case .subtitles:
            TrackPanel(player: player, initialSection: .subtitle)
        case .video:
            VideoSettingsPanel(player: player)
        case .effects:
            AudioEffectsPanel(player: player)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(L("controls.speed", "Playback speed")) { section = .speed }
            Button(L("panel.tracks.audio", "Audio")) { section = .audio }
            Button(L("panel.tracks.subtitle", "Subtitles")) { section = .subtitles }
            Button(L("controls.video-settings", "Video settings")) { section = .video }
            Button(L("controls.audio-effects", "Audio Effects")) { section = .effects }
            Button(L("panel.chapters", "Chapters")) {
                visible = false
                showChapters()
            }
            Divider()
            Button(L("menu.screenshot", "Screenshot"), action: player.screenshot)
                .disabled(player.isIdle)
            Menu(L("menu.ab-loop", "A-B Loop")) {
                Button(L("ab-loop.set-a", "Set Point A"), action: player.setABLoopA).disabled(player.isIdle)
                Button(L("ab-loop.set-b", "Set Point B"), action: player.setABLoopB).disabled(player.isIdle)
                Button(L("ab-loop.clear", "Clear A-B Loop"), action: player.clearABLoop)
                    .disabled(player.abLoopA == nil && player.abLoopB == nil)
            }
            Toggle(L("video.ontop", "Always on Top"), isOn: $player.isOnTop)
        }
        .controlSize(.small)
        .frame(minWidth: 196, alignment: .leading)
        .padding(12)
    }

    private var speed: some View {
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
                Text(speedLabel(player.speed))
                    .monospacedDigit()
                    .foregroundStyle(BrushLLMPlayerTheme.accentText)
                Spacer()
                Button(L("video.delay-reset", "Reset")) { player.speed = 1 }
            }
            Divider()
            HStack(spacing: 4) {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { option in
                    Button(speedLabel(option)) { player.speed = option }
                        .accessibilityAddTraits(player.speed == option ? .isSelected : [])
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(minWidth: 228)
    }

    private func speedLabel(_ speed: Double) -> String {
        "\(speed.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}
