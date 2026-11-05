import SwiftUI

/// Playback ticks update only the timeline, without invalidating the video
/// container, toolbar or sidebar. All callbacks still read the live player.
struct PlaybackProgressView: View {
    @ObservedObject var player: PlayerCore
    @ObservedObject var timeline: PlaybackTimeline
    var compact = false

    /// Local scrub position while dragging the progress bar.
    @State private var scrubPosition: Double = 0

    /// Hover preview: time + horizontal fraction (0…1) on the progress bar.
    @State private var hoverPreview: (time: Double, fraction: CGFloat)?

    var body: some View {
        if compact {
            HStack(spacing: 6) {
                Text(formatTime(player.isScrubbing ? scrubPosition : timeline.position))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(BrushLLMPlayerTheme.controlText)
                    .lineLimit(1)
                    .fixedSize()
                ProgressBar(
                    position: timeline.position,
                    duration: player.duration,
                    chapters: player.chapters,
                    abLoopA: player.abLoopA,
                    abLoopB: player.abLoopB,
                    bookmarks: player.currentFileBookmarks,
                    onScrub: { value in
                        player.isScrubbing = true
                        scrubPosition = value
                    },
                    onScrubEnded: { value in
                        player.isScrubbing = false
                        player.seek(to: value)
                    }
                )
                Text(formatTime(player.duration))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        } else {
            progressRow
        }
    }

    // MARK: - Row 1: progress

    /// Fixed preview card metrics: image 160×90 + time label ≈ 108pt tall.
    private static let previewCardWidth: CGFloat = 160
    private static let previewCardImageHeight: CGFloat = 90
    private static let previewCardTotalHeight: CGFloat = 108

    private var progressRow: some View {
        HStack(spacing: 10) {
            // Time labels: never wrap, fixed single-line. 52pt covers
            // hour-scale times ("1:23:45") in every language.
            Text(formatTime(player.isScrubbing ? scrubPosition : timeline.position))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 52, alignment: .trailing)

            ProgressBar(
                position: timeline.position,
                duration: player.duration,
                chapters: player.chapters,
                abLoopA: player.abLoopA,
                abLoopB: player.abLoopB,
                bookmarks: player.currentFileBookmarks,
                onScrub: { value in
                    player.isScrubbing = true
                    scrubPosition = value
                },
                onScrubEnded: { value in
                    player.isScrubbing = false
                    player.seek(to: value)
                },
                onHover: { fraction, time in
                    if let fraction, let time {
                        hoverPreview = (time, fraction)
                    } else {
                        hoverPreview = nil
                    }
                }
            )
            .frame(height: 18)
            .overlay(alignment: .topLeading) {
                // The preview floats fully above the bar: fixed size, never
                // squashed by the 18pt track, clamped to the bar's width.
                if let preview = hoverPreview, player.duration > 0 {
                    GeometryReader { geometry in
                        let barWidth = geometry.size.width
                        hoverPreviewView(preview)
                            .fixedSize()
                            .offset(x: previewX(preview.fraction, barWidth: barWidth),
                                    y: -Self.previewCardTotalHeight - 6)
                    }
                    .allowsHitTesting(false)
                }
            }

            Text(formatTime(player.duration))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 52, alignment: .leading)
        }
    }

    /// The floating preview card: fixed 160×90 thumbnail (cover) + time label.
    private func hoverPreviewView(_ preview: (time: Double, fraction: CGFloat)) -> some View {
        VStack(spacing: 3) {
            Group {
                if let image = player.thumbnail(at: preview.time) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.black.opacity(0.75))
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
            .frame(width: Self.previewCardWidth, height: Self.previewCardImageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(BrushLLMPlayerTheme.controlSeparator, lineWidth: 0.5)
            }
            Text(formatTime(preview.time))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(BrushLLMPlayerTheme.controlText)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.55), radius: 6)
        .allowsHitTesting(false)
    }

    /// The preview card's leading-x so its center tracks the pointer, clamped
    /// so the card never leaves the bar area.
    private func previewX(_ fraction: CGFloat, barWidth: CGFloat) -> CGFloat {
        let cardWidth = Self.previewCardWidth
        let ideal = fraction * barWidth - cardWidth / 2
        return min(max(ideal, 2), max(barWidth - cardWidth - 2, 2))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

}
