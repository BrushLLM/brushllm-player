import SwiftUI

/// BrushLLM brand palette — brand marks only (About window, protocol badges,
/// server-kind identity). Interactive chrome never uses these; it uses
/// `BrushLLMPlayerTheme` tokens below.
enum BrushPalette {
    static let violet = Color(hex: 0x893CED)
    static let violet300 = Color(hex: 0xD3A5F5)
    static let violet700 = Color(hex: 0x6E24D6)
    /// Warning yellow for error triangles and failure states.
    /// (The old name "orange" was wrong — this value is a yellow.)
    static let warning = Color(hex: 0xF4EA2A)
}

extension Color {
    /// Creates a color from a 24-bit RGB hex value, e.g. `Color(hex: 0x893CED)`.
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

// MARK: - Design scales

/// The only sanctioned corner radii.
enum DesignRadius {
    /// Rows and inline controls.
    static let row: CGFloat = 6
    /// Cards and grouped inputs.
    static let card: CGFloat = 10
    /// Sheets and hero-level surfaces.
    static let sheet: CGFloat = 14
}

/// The only sanctioned chrome icon sizes.
enum DesignIcon {
    /// Inline with text inside panels.
    static let inline: CGFloat = 12
    /// Toolbar / control-bar buttons.
    static let toolbar: CGFloat = 13
    /// The play/pause glyph.
    static let play: CGFloat = 15
}

// MARK: - Player chrome tokens

/// Player chrome design tokens — one accent, one neutral hierarchy, one
/// material ladder:
///
/// - **accent** (lemon) marks discrete selection, activation and primary
///   actions. It is the product's single boldest asset; everything else
///   stays quiet around it.
/// - **white** marks continuous values (progress, volume fills) — the
///   IINA convention: "how much", not "this one".
/// - **black-opacity materials** layer the chrome over the always-black
///   video canvas: bar 85% → panel 72% → control 55%.
///
/// Text contrast on the near-black materials: `controlText` ≈ 15:1,
/// `controlTextSecondary` ≈ 7.6:1, `controlTextHint` ≈ 5:1. Never stack
/// extra `.opacity()` on these — that is how 2.8:1 hint text happened.
enum BrushLLMPlayerTheme {
    /// Lemon accent: selection, activation, primary actions.
    static let accent = Color(hex: 0xE6FF00)
    /// Brand violet for the Settings window surface. The system-preferences
    /// window keeps the brand identity while the player chrome keeps lemon,
    /// so settings controls (toggles, sliders, update banner) read as
    /// product, not player. Violet is mid-dark: pair fills with a white
    /// knob/label — the near-black `onAccent` would disappear on it.
    static let settingsAccent = BrushPalette.violet
    /// Text and icons placed ON the solid accent fill.
    static let onAccent = Color(hex: 0x121212)
    /// Primary text on the dark control material.
    static let controlText = Color.white.opacity(0.92)
    /// Secondary text — ≥4.5:1 on the panel material.
    static let controlTextSecondary = Color.white.opacity(0.60)
    /// Hint text — caption-sized notes only; the floor of the hierarchy.
    static let controlTextHint = Color.white.opacity(0.48)
    /// Background for floating controls over video.
    static let controlMaterial = Color.black.opacity(0.55)
    /// Background for docked side panels (playlist).
    static let panelMaterial = Color.black.opacity(0.72)
    /// Background for the persistent control bar.
    static let barMaterial = Color.black.opacity(0.85)
    /// Hairline separators on the control bar.
    static let controlSeparator = Color.white.opacity(0.12)
    /// Hover fill for chrome buttons and list rows.
    static let hoverFill = Color.white.opacity(0.08)
    /// Opacity applied to disabled chrome (icons, labels).
    static let disabledOpacity: Double = 0.35
}

// MARK: - Shared control styles

/// Switch-style toggle with an explicit on-state color. macOS's NSSwitch
/// ignores SwiftUI tint modifiers (it follows the system accent color), so
/// the capsule is drawn explicitly: accent fill when on, neutral gray when
/// off. The knob flips to near-black on the accent fill for contrast.
struct ThemedSwitchToggleStyle: ToggleStyle {
    /// Fill color for the on-state — the lemon accent everywhere.
    var onColor: Color = BrushLLMPlayerTheme.accent
    /// Knob color while on. Defaults to near-black for bright lemon fills;
    /// mid-dark fills (settings violet) pair with white.
    var onKnobColor: Color = BrushLLMPlayerTheme.onAccent

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? onColor : Color.white.opacity(0.22))
                Circle()
                    .fill(configuration.isOn ? onKnobColor : Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: configuration.isOn ? 9 : -9)
            }
            .frame(width: 36, height: 20)
            .contentShape(.rect)
            .onTapGesture { configuration.isOn.toggle() }
            .animation(.easeInOut(duration: 0.12), value: configuration.isOn)
        }
        .contentShape(.rect)
    }
}

/// Prominent action button: solid accent fill with bold near-black content.
/// `.borderedProminent` + tint renders white text, which is unreadable on
/// the lemon accent — this style keeps the high-contrast pairing.
///
/// Disabled renders as a neutral quiet capsule (white/8 fill, hint-colored
/// label) — dimming the accent by opacity shifts its hue to a muddy olive,
/// so the fill is swapped instead of faded.
struct AccentProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentProminentButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct AccentProminentButtonBody<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let label: Label
    let isPressed: Bool

    var body: some View {
        label
            .font(.callout.weight(.bold))
            .foregroundStyle(isEnabled ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlTextHint)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: DesignRadius.row)
                    .fill(isEnabled ? BrushLLMPlayerTheme.accent : Color.white.opacity(0.08))
            }
            .opacity(isPressed ? 0.75 : 1)
    }
}

/// Glass card treatment for grouped inputs and list cards: white/5 fill,
/// card radius, white/10 hairline; a focused card gets an accent edge.
struct GlassCard: ViewModifier {
    var focused: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: DesignRadius.card)
                    .fill(Color.white.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignRadius.card)
                    .strokeBorder(focused ? BrushLLMPlayerTheme.accent.opacity(0.75) : Color.white.opacity(0.1),
                                  lineWidth: 1)
            }
    }
}
