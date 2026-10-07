import SwiftUI

/// Subtitle styling settings: size, colors, border and position, applied live.
struct SubtitleSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var player = PlayerCore.sharedForSettings

    private let colorSwatches: [(String, String, String)] = [
        // (id, hex, localization key)
        ("white", "#FFFFFFFF", "subtitle.color.white"),
        ("yellow", "#FFE000FF", "subtitle.color.yellow"),
        ("violet", "#893CEDFF", "subtitle.color.violet"),
        ("mint", "#2AEFC8FF", "subtitle.color.mint"),
        ("black", "#000000FF", "subtitle.color.black"),
    ]

    var body: some View {
        Form {
            Section(L("settings.subtitle", "Subtitles")) {
                Toggle(isOn: $settings.autoLoadSubtitles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("subtitle.auto-load", "Auto-load matching subtitles"))
                        Text(L("subtitle.auto-load-hint", "Loads same-named subtitle files from the video's folder; may be slow in large or cloud-synced folders."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(ThemedSwitchToggleStyle(onColor: BrushPalette.violet))

                LabeledContent(L("subtitle.font-size", "Font size")) {
                    Slider(value: $player.subtitleFontSize, in: 12...72, step: 1)
                        .tint(BrushPalette.violet)
                    Text("\(Int(player.subtitleFontSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                LabeledContent(L("subtitle.border-size", "Outline width")) {
                    Slider(value: $player.subtitleBorderSize, in: 0...6, step: 0.5)
                        .tint(BrushPalette.violet)
                    Text(String(format: "%.1f", player.subtitleBorderSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                LabeledContent(L("subtitle.position", "Vertical position")) {
                    Slider(value: $player.subtitlePosition, in: 0...100, step: 1)
                        .tint(BrushPalette.violet)
                    Text("\(Int(player.subtitlePosition))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                LabeledContent(L("subtitle.color", "Text color")) {
                    swatchRow(selection: $player.subtitleColorHex)
                }

                LabeledContent(L("subtitle.border-color", "Outline color")) {
                    swatchRow(selection: $player.subtitleBorderColorHex)
                }

                Text(L("subtitle.live-hint", "Changes apply to the file currently playing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func swatchRow(selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            ForEach(colorSwatches, id: \.0) { swatch in
                Button {
                    selection.wrappedValue = swatch.1
                } label: {
                    Circle()
                        .fill(Color(hexString: swatch.1))
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1)
                        }
                        .overlay {
                            if selection.wrappedValue == swatch.1 {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.black.opacity(0.7))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(L(swatch.2, swatch.0.capitalized))
            }
        }
    }
}

extension Color {
    /// Parses "#RRGGBB" / "#RRGGBBAA" hex strings.
    init(hexString: String) {
        if let color = SubtitleColor(hex: hexString) {
            self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
        } else { self = .clear }
    }
}
