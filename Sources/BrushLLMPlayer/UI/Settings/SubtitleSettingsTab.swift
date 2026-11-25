import SwiftUI

/// Subtitle styling settings: size, colors, border and position, applied live.
struct SubtitleSettingsTab: View {
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
                SubtitleAutoLoadPicker()
                Text(L("subtitle.auto-load-hint", "Applies the next time you open a video."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(L("subtitle.font-size", "Font size")) {
                    Slider(value: $player.subtitleFontSize, in: 12...72, step: 1)
                    Text("\(Int(player.subtitleFontSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                LabeledContent(L("subtitle.border-size", "Outline width")) {
                    Slider(value: $player.subtitleBorderSize, in: 0...6, step: 0.5)
                    Text(String(format: "%.1f", player.subtitleBorderSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                LabeledContent(L("subtitle.position", "Vertical position")) {
                    Slider(value: $player.subtitlePosition, in: 0...100, step: 1)
                    Text("\(Int(player.subtitlePosition))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                LabeledContent(L("subtitle.color", "Text color")) {
                    swatchRow(selection: $player.subtitleColorHex)
                }
                Divider()
                LabeledContent(L("subtitle.border-color", "Outline color")) {
                    swatchRow(selection: $player.subtitleBorderColorHex)
                }

                Text(L("subtitle.live-hint", "Changes apply to the file currently playing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(BrushLLMPlayerTheme.settingsAccent)
    }

    private func swatchRow(selection: Binding<String>) -> some View {
        HStack(spacing: 6) {
            ForEach(colorSwatches, id: \.0) { swatch in
                Button {
                    selection.wrappedValue = swatch.1
                } label: {
                    // The checkmark flips black/white by swatch luminance —
                    // a fixed black mark is invisible on the black swatch.
                    // (Threshold 0.55 keeps mint/yellow on the light side.)
                    let light = SubtitleColor(hex: swatch.1).map {
                        $0.red * 0.299 + $0.green * 0.587 + $0.blue * 0.114 > 0.55
                    } ?? true
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
                                    .foregroundStyle(light ? .black.opacity(0.75) : .white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(L(swatch.2, swatch.0.capitalized))
            }
        }
    }
}

struct SubtitleAutoLoadPicker: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Picker(L("subtitle.auto-load", "Auto-load subtitles"), selection: $settings.subtitleAutoLoad) {
            Text(L("panel.tracks.off", "Off")).tag(AppSettings.SubtitleAutoLoad.off)
            Text(L("subtitle.auto-load-matching", "Matching video name")).tag(AppSettings.SubtitleAutoLoad.matching)
            Text(L("subtitle.auto-load-folder", "All in the same folder")).tag(AppSettings.SubtitleAutoLoad.folder)
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
