import SwiftUI

/// Picture settings popover from the control bar: aspect handling, rotation,
/// crop, HDR output and hardware decoding — the low-frequency video options
/// collected behind one button instead of cluttering the bar.
struct VideoSettingsPanel: View {
    @ObservedObject var player: PlayerCore
    @ObservedObject private var settings = AppSettings.shared

    /// Fixed ratios offered alongside fit/fill/stretch.
    private static let customRatios: [String] = ["4:3", "16:9", "2.35:1", "1:1"]

    /// Rotation choices, clockwise.
    private static let rotations: [Int] = [0, 90, 180, 270]

    /// Human-readable hardware-decoding status. mpv reports raw decoder
    /// names ("videotoolbox-copy"…) — showing them verbatim confused users.
    private var hwdecStatus: String? {
        guard let hwdec = player.hwdecCurrent?.lowercased(), !hwdec.isEmpty, hwdec != "no" else {
            return nil
        }
        if hwdec.contains("videotoolbox") {
            return L("video.hwdec.active", "Active · VideoToolbox")
        }
        return L("video.hwdec.active", "Active") + " · " + hwdec
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(title: L("video.aspect", "Aspect Ratio")) {
                    modeRow(L("video.aspect.fit", "Fit to Window"), mode: .fit)
                    modeRow(L("video.aspect.fill", "Fill Window"), mode: .fill)
                    modeRow(L("video.aspect.stretch", "Stretch to Window"), mode: .stretch)
                    ForEach(Self.customRatios, id: \.self) { ratio in
                        ratioRow(ratio)
                    }
                }

                Divider().padding(.vertical, 8)

                PanelSection(title: L("video.rotate", "Rotation")) {
                    rotationRow
                }

                Divider().padding(.vertical, 8)

                PanelSection(title: L("video.crop", "Crop")) {
                    cropGrid
                    if player.cropMode == .custom {
                        VStack(spacing: 6) {
                            marginRow(L("video.crop.top", "Top"), value: $player.cropTop)
                            marginRow(L("video.crop.bottom", "Bottom"), value: $player.cropBottom)
                            marginRow(L("video.crop.left", "Left"), value: $player.cropLeft)
                            marginRow(L("video.crop.right", "Right"), value: $player.cropRight)
                        }
                        .padding(.top, 6)
                    }
                }

                Divider().padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $player.hdrEnabled) {
                        Text(L("video.hdr", "HDR Output"))
                            .font(.callout)
                            .foregroundStyle(BrushLLMPlayerTheme.controlText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(ThemedSwitchToggleStyle())

                    Toggle(isOn: $settings.hardwareDecoding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("video.hwdec", "Hardware Decoding"))
                                .font(.callout)
                                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                            if let status = hwdecStatus {
                                Text(status)
                                    .font(.caption2)
                                    .foregroundStyle(BrushLLMPlayerTheme.accent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(ThemedSwitchToggleStyle())
                }
            }
            .padding(12)
        }
        .frame(minWidth: 280, maxWidth: 340, maxHeight: 560)
    }

    // MARK: - Aspect rows

    private func modeRow(_ label: String, mode: PlayerCore.AspectMode) -> some View {
        SelectableRow(selected: player.aspectMode == mode && mode != .custom, action: {
            settings.aspectMode = mode
            player.aspectMode = mode
        }) {
            rowLabel(label,
                     selected: player.aspectMode == mode && mode != .custom)
        }
    }

    private func ratioRow(_ ratio: String) -> some View {
        let selected = player.aspectMode == .custom && player.aspectOverride == ratio
        return SelectableRow(selected: selected, action: {
            settings.aspectMode = .custom
            settings.aspectOverride = ratio
            player.aspectMode = .custom
            player.aspectOverride = ratio
        }) {
            rowLabel(ratio, selected: selected)
        }
    }

    /// Label + trailing checkmark inside a selectable row.
    private func rowLabel(_ text: String, selected: Bool) -> some View {
        HStack {
            Text(text)
                .font(.callout)
                .fontWeight(selected ? .bold : .regular)
                .monospacedDigit()
                .foregroundStyle(selected ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlText)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(BrushLLMPlayerTheme.onAccent)
            }
        }
    }

    // MARK: - Rotation

    /// Four equal segments: 0° / 90° / 180° / 270°, clockwise.
    private var rotationRow: some View {
        HStack(spacing: 4) {
            ForEach(Self.rotations, id: \.self) { degrees in
                segmentButton("\(degrees)°", selected: player.videoRotation == degrees) {
                    player.videoRotation = degrees
                }
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Crop

    /// Crop choices in a 3×2 grid: Off / ratio presets / Custom.
    private var cropGrid: some View {
        let items: [(label: String, action: () -> Void, selected: Bool)] = [
            (L("video.crop.off", "Off"), { player.cropMode = .off }, player.cropMode == .off),
            ("4:3", { player.setCropRatio("4:3") }, player.cropMode == .ratio && player.cropRatio == "4:3"),
            ("16:9", { player.setCropRatio("16:9") }, player.cropMode == .ratio && player.cropRatio == "16:9"),
            ("2.35:1", { player.setCropRatio("2.35:1") }, player.cropMode == .ratio && player.cropRatio == "2.35:1"),
            ("1:1", { player.setCropRatio("1:1") }, player.cropMode == .ratio && player.cropRatio == "1:1"),
            (L("video.crop.custom", "Custom"), { player.cropMode = .custom }, player.cropMode == .custom),
        ]
        let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                segmentButton(item.label, selected: item.selected, action: item.action)
            }
        }
        .padding(.horizontal, 2)
    }

    /// One equal-width segment in a segmented group (rotation / crop grid).
    private func segmentButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .fontWeight(selected ? .bold : .regular)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(selected ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: DesignRadius.row)
                            .fill(BrushLLMPlayerTheme.accent)
                    }
                }
        }
        .buttonStyle(PressedDimButtonStyle())
    }

    /// One custom-crop margin slider (percent of the source dimension).
    private func marginRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
            Slider(value: value, in: 0...45, step: 1)
                .tint(BrushLLMPlayerTheme.accent)
            Text("\(Int(value.wrappedValue))%")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}
