import SwiftUI

/// Playback timeline with chapter, loop and bookmark markers.
struct ProgressBar: View {
    let position: Double
    let duration: Double
    let chapters: [ChapterInfo]
    let abLoopA: Double?
    let abLoopB: Double?
    var bookmarks: [Bookmark] = []
    let canSeek: Bool
    let showsTimeHint: Bool
    @Binding var dragPosition: Double?
    let onSeek: (Double) -> Void
    @State private var isHovering = false
    @State private var hoverFraction: CGFloat?

    private var effectivePosition: Double {
        dragPosition ?? position
    }

    private var showsKnob: Bool { canSeek && (dragPosition != nil || isHovering) }

    private var fraction: CGFloat {
        duration > 0 ? CGFloat(min(max(effectivePosition / duration, 0), 1)) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let barHeight: CGFloat = 4
            let barY = (height - barHeight) / 2

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(BrushLLMPlayerTheme.controlSeparator)
                    .frame(width: width, height: barHeight)
                    .position(x: width / 2, y: height / 2)

                // Played portion of the timeline.
                Capsule()
                    .fill(BrushLLMPlayerTheme.accent)
                    .frame(width: max(fraction * width, barHeight), height: barHeight)
                    .position(x: max(fraction * width, barHeight) / 2, y: height / 2)

                // Chapter tick marks
                ForEach(chapters) { chapter in
                    if duration > 0 {
                        let x = CGFloat(chapter.startTime / duration) * width
                        Rectangle()
                            .fill(BrushLLMPlayerTheme.controlTextHint)
                            .frame(width: 1.5, height: barHeight + 4)
                            .position(x: x, y: barY + barHeight / 2)
                    }
                }

                // A-B loop markers
                if let a = abLoopA, duration > 0 {
                    abMarker(x: CGFloat(a / duration) * width, y: barY + barHeight / 2, label: "A")
                }
                if let b = abLoopB, duration > 0 {
                    abMarker(x: CGFloat(b / duration) * width, y: barY + barHeight / 2, label: "B")
                }

                // Bookmark markers (accent)
                ForEach(bookmarks) { bookmark in
                    if duration > 0 {
                        let x = CGFloat(bookmark.time / duration) * width
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(BrushLLMPlayerTheme.accent)
                            .position(x: x, y: barY - 2)
                    }
                }

                // Knob
                Circle()
                    .fill(BrushLLMPlayerTheme.accent)
                    .frame(width: showsKnob ? 12 : 0, height: showsKnob ? 12 : 0)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: fraction * width, y: height / 2)
                    .animation(.easeInOut(duration: 0.12), value: showsKnob)
            }
            .frame(width: width, height: height)
            .overlay {
                if showsTimeHint, let hoverFraction, duration > 0 {
                    let halfWidth: CGFloat = 32
                    let x = min(max(hoverFraction * width, halfWidth), max(width - halfWidth, halfWidth))
                    Text(playbackClock(Double(hoverFraction) * duration))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(BrushLLMPlayerTheme.seekHintText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .frame(maxWidth: halfWidth * 2)
                        .background(BrushLLMPlayerTheme.seekHintMaterial, in: .rect(cornerRadius: 5))
                        .fixedSize()
                        .position(x: x, y: height / 2)
                        .accessibilityHidden(true)
                }
            }
            .allowsHitTesting(false)
            .overlay { seekTarget(width: width) }
        }
        .frame(height: 18)
        .accessibilityRepresentation {
            Slider(value: Binding(
                get: { min(max(effectivePosition, 0), max(duration, 0.001)) },
                set: onSeek
            ), in: 0...max(duration, 0.001), step: min(5, max(duration, 0.001))) {
                Text(L("controls.progress", "Playback position"))
            }
            .disabled(!canSeek)
            .accessibilityValue("\(playbackClock(effectivePosition)) / \(playbackClock(duration))")
        }
    }

    // MARK: - Pieces

    private func seekTarget(width: CGFloat) -> some View {
        Color.clear
            .contentShape(.rect)
            .onHover { hovering in
                isHovering = hovering
                if !hovering { hoverFraction = nil }
            }
            .onContinuousHover { phase in
                guard showsTimeHint, width > 0 else { return }
                switch phase {
                case .active(let location):
                    hoverFraction = min(max(location.x / width, 0), 1)
                case .ended:
                    hoverFraction = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard canSeek else { return }
                        dragPosition = value(forX: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        dragPosition = nil
                        guard canSeek else { return }
                        onSeek(value(forX: gesture.location.x, width: width))
                    }
            )
    }

    private func abMarker(x: CGFloat, y: CGFloat, label: String) -> some View {
        ZStack {
            Rectangle()
                .fill(BrushLLMPlayerTheme.accent)
                .frame(width: 2, height: 14)
            Text(label)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(BrushLLMPlayerTheme.accent)
                .offset(y: -9)
        }
        .position(x: x, y: y)
    }

    private func value(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        let clamped = min(max(x / width, 0), 1)
        return clamped * duration
    }
}
