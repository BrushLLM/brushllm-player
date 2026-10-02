import SwiftUI

/// BrushLLM brand palette, extracted from brushllm.pages.dev.
/// See docs/design-system.md for the source values and usage rules.
enum BrushPalette {
    static let violet = Color(hex: 0x893CED)
    static let violet50 = Color(hex: 0xFAF3FE)
    static let violet100 = Color(hex: 0xF3E4FD)
    static let violet200 = Color(hex: 0xE6C9FA)
    static let violet300 = Color(hex: 0xD3A5F5)
    static let violet400 = Color(hex: 0xBC72EE)
    static let violet500 = Color(hex: 0xA840EE)
    static let violet700 = Color(hex: 0x6E24D6)

    static let orange = Color(hex: 0xF4EA2A)
    static let mint = Color(hex: 0x2AEFC8)
    /// Lemon yellow for timeline bookmark markers.
    static let lemon = Color(hex: 0xFFE135)

    static let ink = Color(hex: 0x1A1B25)
    static let muted = Color(hex: 0x565870)

    static let stone50 = Color(hex: 0xFAFAF9)
    static let stone100 = Color(hex: 0xF5F5F4)
    static let stone200 = Color(hex: 0xE7E5E4)
    static let stone300 = Color(hex: 0xD6D3D1)
    static let stone400 = Color(hex: 0xA8A29E)
    static let stone500 = Color(hex: 0x78716C)
    static let stone600 = Color(hex: 0x57534E)
    static let stone700 = Color(hex: 0x44403C)
    static let stone800 = Color(hex: 0x292524)
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

/// Player-specific semantic colors: the video area is always black; controls
/// float above it on a dark translucent material regardless of system appearance.
/// The accent is a high-saturation lemon yellow — on the black chrome it is
/// instantly readable, and selected controls pair the solid yellow fill with
/// bold near-black content (`onAccent`) for maximum contrast.
enum BrushLLMPlayerTheme {
    /// Lemon yellow accent for active/selected states.
    static let accent = Color(hex: 0xE6FF00)
    /// Text and icons placed ON the solid accent fill (selected states).
    static let onAccent = Color(hex: 0x121212)
    /// Text on the dark control material.
    static let controlText = Color.white.opacity(0.92)
    static let controlTextSecondary = Color.white.opacity(0.55)
    /// Background for floating controls over video.
    static let controlMaterial = Color.black.opacity(0.55)
    /// Background for docked side panels (playlist).
    static let panelMaterial = Color.black.opacity(0.72)
    /// Background for the persistent control bar.
    static let barMaterial = Color.black.opacity(0.85)
    /// Hairline separators on the control bar.
    static let controlSeparator = Color.white.opacity(0.12)
}

/// Switch-style toggle with an explicit on-state color. macOS's NSSwitch
/// ignores SwiftUI tint modifiers (it follows the system accent color), so
/// the capsule is drawn explicitly: the on-color fill when on, neutral gray
/// when off, white knob either way.
struct ThemedSwitchToggleStyle: ToggleStyle {
    /// Fill color for the on-state — lemon in the player panels, brand
    /// violet in the settings window.
    var onColor: Color = BrushLLMPlayerTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            ZStack {
                Capsule()
                    .fill(configuration.isOn ? onColor : Color.white.opacity(0.22))
                Circle()
                    .fill(Color.white)
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
struct AccentProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.bold))
            .foregroundStyle(BrushLLMPlayerTheme.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(BrushLLMPlayerTheme.accent)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
