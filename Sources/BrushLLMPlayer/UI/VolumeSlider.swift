import SwiftUI

/// Compact volume slider with a deliberately small knob (7pt), sized to sit
/// next to a 13pt toolbar icon without visual imbalance.
struct VolumeSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>

    @State private var isDragging = false

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let trackHeight: CGFloat = 3

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: width, height: trackHeight)
                    .position(x: width / 2, y: height / 2)

                // Fill — brand violet (kept distinct from the lemon accent)
                Capsule()
                    .fill(BrushPalette.violet)
                    .frame(width: max(fraction * width, trackHeight), height: trackHeight)
                    .position(x: max(fraction * width, trackHeight) / 2, y: height / 2)

                // Small knob
                Circle()
                    .fill(BrushPalette.violet)
                    .frame(width: 7, height: 7)
                    .shadow(color: BrushPalette.violet.opacity(0.4), radius: 1.5)
                    .position(x: fraction * width, y: height / 2)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        guard width > 0 else { return }
                        let clamped = min(max(gesture.location.x / width, 0), 1)
                        let span = range.upperBound - range.lowerBound
                        value = range.lowerBound + clamped * span
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 18)
    }
}
