import SwiftUI

/// Playback ticks update only the timeline, without invalidating the video
/// container, toolbar or sidebar.
struct PlaybackProgressView: View {
    @ObservedObject var player: PlayerCore
    @ObservedObject var timeline: PlaybackTimeline
    var compact = false
    @State private var dragPosition: Double?

    var body: some View {
        let generation = player.loadGeneration
        HStack(spacing: compact ? 6 : 10) {
            timeLabel(dragPosition ?? timeline.position, trailing: true)
            ProgressBar(
                position: timeline.position,
                duration: player.duration,
                chapters: player.chapters,
                abLoopA: player.abLoopA,
                abLoopB: player.abLoopB,
                bookmarks: player.currentFileBookmarks,
                canSeek: player.canSeekTimeline,
                showsTimeHint: !compact && player.canSeekTimeline,
                dragPosition: $dragPosition,
                onSeek: { player.seekTimeline(to: $0, generation: generation) }
            )
            timeLabel(player.duration, trailing: false)
        }
    }

    private func timeLabel(_ seconds: Double, trailing: Bool) -> some View {
        Text(playbackClock(seconds))
            .font(.system(size: compact ? 10 : 11, weight: .medium).monospacedDigit())
            .foregroundStyle(trailing ? BrushLLMPlayerTheme.controlText : BrushLLMPlayerTheme.controlTextSecondary)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: compact ? nil : 52, alignment: trailing ? .trailing : .leading)
    }
}
