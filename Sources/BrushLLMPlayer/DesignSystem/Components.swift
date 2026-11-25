import SwiftUI
import AppKit

struct PlayerIcon: View {
    let size: CGFloat

    private static let image = Bundle.main.url(forResource: "PlayerIcon", withExtension: "svg", subdirectory: "Base.lproj")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "play.rectangle").font(.system(size: size * 0.7))
                    .foregroundStyle(BrushLLMPlayerTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Packs controls or short labels in rows at their intrinsic widths.
struct WrappingRows: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(for: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let pack = positions(for: subviews, width: bounds.width)
        for (index, point) in pack.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  anchor: .topLeading, proposal: .unspecified)
        }
    }

    private func positions(for subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var point = CGPoint.zero
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var origins: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if point.x > 0, point.x + size.width > width {
                point = CGPoint(x: 0, y: point.y + rowHeight + spacing)
                rowHeight = 0
            }
            origins.append(point)
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, point.x + size.width)
            point.x += size.width + spacing
        }
        return (origins, CGSize(width: usedWidth, height: point.y + rowHeight))
    }
}

// MARK: - Chrome icon button

/// Chrome icon button with hover, focus, pressed, disabled and active states.
///
/// Renders identically under ImageRenderer snapshots (hover is inert
/// offscreen), so the control bar's live-resize snapshot keeps working.
struct PlayerIconButton: View {
    let icon: String
    var iconSize: CGFloat = DesignIcon.toolbar
    var width: CGFloat = 32
    var height: CGFloat = 32
    let help: String
    var active: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(active ? BrushLLMPlayerTheme.accentText : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: width, height: height)
                .background {
                    if active || (isHovering && !disabled) {
                        RoundedRectangle(cornerRadius: DesignRadius.row)
                            .fill(active ? BrushLLMPlayerTheme.selectionFill : BrushLLMPlayerTheme.hoverFill)
                    }
                }
                .opacity(disabled ? BrushLLMPlayerTheme.disabledOpacity : 1)
                .contentShape(.rect)
        }
        .buttonStyle(PressedDimButtonStyle())
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            isHovering = hovering && !disabled
        }
    }
}

/// Pressed feedback that dims without shifting layout bounds.
struct PressedDimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusFeedback(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct FocusFeedback<Label: View>: View {
        @Environment(\.isFocused) private var isFocused
        let label: Label
        let isPressed: Bool

        var body: some View {
            label
                .opacity(isPressed ? 0.65 : 1)
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: DesignRadius.row)
                            .strokeBorder(BrushLLMPlayerTheme.accentText, lineWidth: 2)
                    }
                }
        }
    }
}

// MARK: - Hover-bright icon button

/// Quiet icon-only button (list-row deletes and similar tertiary actions):
/// 14pt glyph in a 24×24 hit target, dimmed at rest and brightening on
/// hover so it reads as clickable without competing with row content.
struct HoverBrightButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isHovering ? BrushLLMPlayerTheme.controlText
                                            : BrushLLMPlayerTheme.controlTextHint)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(PressedDimButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Panel section

/// A titled section inside a popover/panel: caption header + content with
/// the section spacing scale. Replaces the per-file header paddings.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
            content
        }
    }
}

// MARK: - Empty & error states

/// One empty-state pattern for every list: icon, message, optional action.
struct EmptyStateView: View {
    let icon: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(BrushLLMPlayerTheme.controlTextHint)
            Text(message)
                .font(.callout)
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(AccentProminentButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// One error-state pattern: warning icon, message, optional retry.
struct ErrorStateView: View {
    let message: String
    var retryTitle: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(BrushLLMPlayerTheme.warning)
            Text(message)
                .font(.callout)
                .foregroundStyle(BrushLLMPlayerTheme.controlTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            if let retryTitle, let retry {
                Button(retryTitle, action: retry)
                    .buttonStyle(AccentProminentButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Badge

/// Small tinted capsule badge (server kind, protocol). 9pt floor —
/// 8pt all-caps text was below the readable minimum.
struct KindBadge: View {
    let text: String
    var tint: Color = BrushLLMPlayerTheme.accentText

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                Capsule().fill(BrushLLMPlayerTheme.selectionFill)
            }
    }
}
