import SwiftUI

// MARK: - Chrome icon button

/// Standard chrome icon button: one size (13pt symbol in a 28×28 hit target),
/// hover fill, pressed dimming, a visible disabled state, and an optional
/// active accent. Replaces the per-file inline icon buttons that had no
/// hover or disabled treatment.
///
/// Renders identically under ImageRenderer snapshots (hover is inert
/// offscreen), so the control bar's live-resize snapshot keeps working.
struct PlayerIconButton: View {
    let icon: String
    var iconSize: CGFloat = DesignIcon.toolbar
    var width: CGFloat = 28
    let help: String
    var active: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(active ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlTextSecondary)
                .frame(width: width, height: 28)
                .background {
                    if isHovering && !disabled {
                        RoundedRectangle(cornerRadius: DesignRadius.row)
                            .fill(BrushLLMPlayerTheme.hoverFill)
                    }
                }
                .opacity(disabled ? BrushLLMPlayerTheme.disabledOpacity : 1)
                .contentShape(.rect)
        }
        .buttonStyle(PressedDimButtonStyle())
        .disabled(disabled)
        .help(help)
        .onHover { hovering in
            isHovering = hovering && !disabled
        }
    }
}

/// Pressed feedback that dims without shifting layout bounds.
struct PressedDimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
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
                .foregroundStyle(BrushPalette.warning)
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
    var tint: Color = BrushPalette.violet300

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                Capsule().fill(BrushPalette.violet.opacity(0.18))
            }
    }
}
