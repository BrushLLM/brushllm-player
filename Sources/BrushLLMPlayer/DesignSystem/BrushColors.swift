import SwiftUI
import AppKit

extension Color {
    /// Creates a color from a 24-bit RGB hex value, e.g. `Color(hex: 0x20594F)`.
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
    static let row: CGFloat = 8
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

/// Semantic desktop colors shared with the Tauri client. The video matte
/// is fixed so turning on light appearance never changes video letterboxing.
enum BrushLLMPlayerTheme {
    private static let teal: UInt32 = 0x20594F
    private static let sage: UInt32 = 0xC6DED2
    private static let viewingBackground: UInt32 = 0x171717
    private static let viewingForeground: UInt32 = 0xF2F2F1
    private static let viewingForegroundSecondary: UInt32 = 0xB5B7B4

    static let window = adaptive(light: 0xF5F4F0, dark: viewingBackground)
    static let rail = adaptive(light: 0xECEBE6, dark: 0x1D1D1D)
    static let panelMaterial = adaptive(light: 0xFFFEFC, dark: 0x252525)
    static let videoMatte = Color(hex: 0x101010)
    static let viewingSurface = Color(hex: viewingBackground)
    static let viewingText = Color(hex: viewingForeground)
    static let viewingTextSecondary = Color(hex: viewingForegroundSecondary)
    static let viewingAccent = Color(hex: sage)
    static let viewingSelection = Color(hex: 0x2A3631)
    static let accent = adaptive(light: teal, dark: sage)
    static let accentText = accent
    static let settingsAccent = accent
    static let onAccent = adaptive(light: viewingForeground, dark: 0x17221E)
    static let seekHintMaterial = videoMatte
    static let seekHintText = viewingText
    static let controlText = adaptive(light: 0x202624, dark: viewingForeground)
    static let controlTextSecondary = adaptive(light: 0x545D58, dark: viewingForegroundSecondary)
    static let controlTextHint = adaptive(light: 0x656D67, dark: 0xA6AAA7)
    static let controlMaterial = panelMaterial
    static let controlSeparator = adaptive(light: 0xD4D7D2, dark: 0x414441)
    static let hoverFill = adaptive(light: 0xE6E7E2, dark: 0x303230)
    static let selectionFill = adaptive(light: 0xE2EEE7, dark: 0x2A3631)
    static let warning = adaptive(light: 0x805711, dark: 0xE8BA60)
    static let disabledOpacity: Double = 0.42

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

// MARK: - Shared control styles

/// Switch-style toggle with an explicit on-state color. macOS's NSSwitch
/// ignores SwiftUI tint modifiers (it follows the system accent color), so
/// the capsule is drawn explicitly: accent fill when on, neutral gray when
/// off. The knob uses the foreground for the active appearance.
struct ThemedSwitchToggleStyle: ToggleStyle {
    var onColor: Color = BrushLLMPlayerTheme.accent
    var onKnobColor: Color = BrushLLMPlayerTheme.onAccent

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? onColor : BrushLLMPlayerTheme.controlSeparator)
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

/// Solid accent action with a theme-specific foreground.
struct AccentProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentProminentButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct AccentProminentButtonBody<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    let label: Label
    let isPressed: Bool

    var body: some View {
        label
            .font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? BrushLLMPlayerTheme.onAccent : BrushLLMPlayerTheme.controlTextHint)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background {
                RoundedRectangle(cornerRadius: DesignRadius.row)
                    .fill(isEnabled ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.hoverFill)
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: DesignRadius.card)
                        .strokeBorder(BrushLLMPlayerTheme.accentText, lineWidth: 2)
                        .padding(-3)
                }
            }
            .opacity(isPressed ? 0.75 : 1)
    }
}

/// Grouped inputs and list rows with a focus border.
struct GlassCard: ViewModifier {
    var focused: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: DesignRadius.card)
                    .fill(BrushLLMPlayerTheme.window)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignRadius.card)
                    .strokeBorder(focused ? BrushLLMPlayerTheme.accent : BrushLLMPlayerTheme.controlSeparator,
                                  lineWidth: 1)
            }
    }
}
