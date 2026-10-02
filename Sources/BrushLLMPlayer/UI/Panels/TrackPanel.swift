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
                sectionHeader(L("panel.tracks.audio", "Audio"))
                trackRows(player.audioTracks, current: player.currentAudioTrack) { id in
                    player.setAudioTrack(id)
                }
            case .subtitle:
                sectionHeader(L("panel.tracks.subtitle", "Subtitles"))
                trackRows(player.subtitleTracks, current: player.currentSubtitleTrack) { id in
                    player.setSubtitleTrack(id)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 240, maxWidth: 320)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
            .padding(.bottom, 4)
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
        Button(action: action) {
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
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(BrushLLMPlayerTheme.accent)
            }
        }
    }
}
