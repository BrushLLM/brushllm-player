import SwiftUI

/// Custom video progress bar: hairline track, white fill (IINA-style),
/// chapter tick marks, A-B loop markers, and a round knob that appears
/// while scrubbing.
struct ProgressBar: View {
    let position: Double
    let duration: Double
    let chapters: [ChapterInfo]
    let abLoopA: Double?
    let abLoopB: Double?
    /// Bookmarks of the current file, drawn as mint markers.
    var bookmarks: [Bookmark] = []
    /// Live scrub position while dragging.
    var onScrub: (Double) -> Void
    /// Final seek when the drag or click ends.
    var onScrubEnded: (Double) -> Void
    /// Hover for the thumbnail preview: horizontal fraction (0…1) and time;
    /// nil when the pointer leaves.
    var onHover: (CGFloat?, Double?) -> Void = { _, _ in }

    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var isHovering = false

    private var effectivePosition: Double {
        isDragging ? dragValue : position
    }

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
                    .fill(Color.white.opacity(0.22))
                    .frame(width: width, height: barHeight)
                    .position(x: width / 2, y: height / 2)

                // Fill — white, IINA-style
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: max(fraction * width, barHeight), height: barHeight)
                    .position(x: max(fraction * width, barHeight) / 2, y: height / 2)

                // Chapter tick marks
                ForEach(chapters) { chapter in
                    if duration > 0 {
                        let x = CGFloat(chapter.startTime / duration) * width
                        Rectangle()
                            .fill(Color.white.opacity(0.45))
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

                // Bookmark markers (lemon yellow)
                ForEach(bookmarks) { bookmark in
                    if duration > 0 {
                        let x = CGFloat(bookmark.time / duration) * width
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(BrushPalette.lemon)
                            .position(x: x, y: barY - 2)
                    }
                }

                // Knob
                Circle()
                    .fill(Color.white)
                    .frame(width: isDragging || isHovering ? 12 : 0, height: isDragging || isHovering ? 12 : 0)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: fraction * width, y: height / 2)
                    .animation(.easeInOut(duration: 0.12), value: isDragging || isHovering)
            }
            .contentShape(.rect)
            .onHover { hovering in
                isHovering = hovering
                if !hovering { onHover(nil, nil) }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard duration > 0, width > 0 else { return }
                    let fraction = min(max(location.x / width, 0), 1)
                    onHover(fraction, fraction * duration)
                case .ended:
                    onHover(nil, nil)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                        }
                        dragValue = value(forX: gesture.location.x, width: width)
                        onScrub(dragValue)
                    }
                    .onEnded { gesture in
                        let final = value(forX: gesture.location.x, width: width)
                        isDragging = false
                        dragValue = final
                        onScrubEnded(final)
                    }
            )
        }
        .frame(height: 18)
    }

    // MARK: - Pieces

    private func abMarker(x: CGFloat, y: CGFloat, label: String) -> some View {
        ZStack {
            Rectangle()
                .fill(BrushPalette.orange)
                .frame(width: 2, height: 14)
            Text(label)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(BrushPalette.orange)
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
