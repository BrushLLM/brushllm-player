import SwiftUI

/// Audio & subtitle track picker, shown as a popover from the control bar.
/// Each button opens only its own section — the headphones button shows audio
/// tracks, the CC button shows subtitles.
struct TrackPanel: View {
    @ObservedObject var player: PlayerCore

    enum Section {
        case audio
        case subtitle
    }

    /// Which section this panel manages.
    var initialSection: Section = .audio

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch initialSection {
            case .audio:
                PanelSection(title: L("panel.tracks.audio", "Audio")) {
                    trackRows(player.audioTracks, current: player.currentAudioTrack) { id in
                        player.setAudioTrack(id)
                    }
                }
            case .subtitle:
                PanelSection(title: L("panel.tracks.subtitle", "Subtitles")) {
                    trackRows(player.subtitleTracks, current: player.currentSubtitleTrack) { id in
                        player.setSubtitleTrack(id)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 240, maxWidth: 320)
    }

    @ViewBuilder
    private func trackRows(_ tracks: [TrackInfo], current: Int?, action: @escaping (Int?) -> Void) -> some View {
        if tracks.isEmpty {
            Text(L("panel.tracks.none", "No tracks"))
                .font(.caption)
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .padding(.bottom, 8)
        } else {
            // "Off" row (disables the track type).
            trackRow(label: L("panel.tracks.off", "Off"), isSelected: current == nil) {
                action(nil)
            }
            ForEach(tracks) { track in
                trackRow(label: track.label, isSelected: track.id == current) {
                    action(track.id)
                }
            }
        }
    }

    private func trackRow(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        SelectableRow(selected: isSelected, action: action) {
            HStack {
                Text(label)
                    .font(.callout)
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundStyle(isSelected ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlText)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(BrushLLMPlayerTheme.onAccent)
                }
            }
        }
    }
}

// MARK: - Selectable row

/// The shared selection-row pattern: accent fill when selected, hover fill
/// otherwise, pressed dimming. Content provides its own conditional colors.
struct SelectableRow<Content: View>: View {
    var selected: Bool = false
    var action: () -> Void
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: DesignRadius.row)
                            .fill(BrushLLMPlayerTheme.accent)
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: DesignRadius.row)
                            .fill(BrushLLMPlayerTheme.hoverFill)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(PressedDimButtonStyle())
        .onHover { isHovering = $0 }
    }
}
