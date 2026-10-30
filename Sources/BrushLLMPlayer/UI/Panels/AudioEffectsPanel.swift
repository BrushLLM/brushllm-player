import SwiftUI

/// Audio effects popover from the control bar: the three-band equalizer and
/// the A/V sync delay adjustment collected behind one button.
struct AudioEffectsPanel: View {
    @ObservedObject var player: PlayerCore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // MARK: Equalizer

                Toggle(isOn: $player.eqEnabled) {
                    Text(L("controls.equalizer", "Equalizer"))
                        .font(.callout)
                        .foregroundStyle(BrushLLMPlayerTheme.controlText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(ThemedSwitchToggleStyle())

                if player.eqEnabled {
                    band(L("eq.bass", "Bass"), value: $player.eqBass)
                    band(L("eq.mid", "Mid"), value: $player.eqMid)
                    band(L("eq.treble", "Treble"), value: $player.eqTreble)

                    HStack(spacing: 6) {
                        presetButton(L("eq.preset.flat", "Flat"), bass: 0, mid: 0, treble: 0)
                        presetButton(L("eq.preset.pop", "Pop"), bass: 3, mid: 0, treble: 2)
                        presetButton(L("eq.preset.rock", "Rock"), bass: 5, mid: -1, treble: 4)
                        presetButton(L("eq.preset.voice", "Voice"), bass: -2, mid: 5, treble: 1)
                    }
                }

                Divider().overlay(BrushLLMPlayerTheme.controlSeparator)

                // MARK: A/V sync

                PanelSection(title: L("video.sync", "A/V Sync")) {
                    delayRow(L("video.audio-delay", "Audio delay"), value: $player.audioDelay)
                    delayRow(L("video.video-delay", "Video delay"), value: $player.videoDelay)

                    Button {
                        player.resetDelays()
                    } label: {
                        Text(L("video.delay-reset", "Reset"))
                            .font(.caption)
                            .foregroundStyle(BrushLLMPlayerTheme.accent)
                    }
                    .buttonStyle(PressedDimButtonStyle())
                    .padding(.top, 2)
                }

                Divider().overlay(BrushLLMPlayerTheme.controlSeparator)

                // MARK: Subtitle delay

                PanelSection(title: L("panel.tracks.subtitle", "Subtitles")) {
                    delayRow(L("subtitle.delay", "Subtitle delay"), value: $player.subtitleDelay)
                }

                Divider().overlay(BrushLLMPlayerTheme.controlSeparator)

                // MARK: Speed / pitch

                Toggle(isOn: $player.preservesPitch) {
                    Text(L("audio.preserve-pitch", "Keep pitch when changing speed"))
                        .font(.callout)
                        .foregroundStyle(BrushLLMPlayerTheme.controlText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(ThemedSwitchToggleStyle())

                Divider().overlay(BrushLLMPlayerTheme.controlSeparator)

                // MARK: Audio output device (IINA audioDeviceMenu)

                PanelSection(title: L("audio.device", "Audio Output")) {
                    Picker(L("audio.device", "Audio Output"), selection: $player.audioDevice) {
                        Text(L("audio.device-default", "System Default")).tag("auto")
                        ForEach(player.audioDevices, id: \.device) { device in
                            Text(device.name).tag(device.device)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 270, maxWidth: 320, maxHeight: 460)
    }

    // MARK: - Equalizer

    private func band(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 34, alignment: .leading)
            Slider(value: value, in: -12...12, step: 0.5)
                .tint(BrushLLMPlayerTheme.accent)
            Text(String(format: "%+.1f", value.wrappedValue))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func presetButton(_ label: String, bass: Double, mid: Double, treble: Double) -> some View {
        Button {
            player.eqBass = bass
            player.eqMid = mid
            player.eqTreble = treble
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(BrushLLMPlayerTheme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(BrushLLMPlayerTheme.accent.opacity(0.14))
                }
        }
        .buttonStyle(PressedDimButtonStyle())
    }

    // MARK: - A/V sync

    private func delayRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
            Slider(value: value, in: -5...5, step: 0.05)
                .tint(BrushLLMPlayerTheme.accent)
            Text(String(format: "%+.2fs", value.wrappedValue))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
