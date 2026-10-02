import Foundation

/// In-app localization with an optional language override.
///
/// All string tables are compiled into the binary (`GeneratedStrings`), so
/// lookups are pure dictionary hits with no file access at runtime. The system
/// language is resolved from the user's preferred languages; an explicit
/// override redirects lookups to that table instead — no restart needed.
enum Localization {

    /// Languages shipped in the product, in the required order.
    /// `code == nil` means "follow the system language".
    static let supportedLanguages: [LanguageOption] = [
        .init(code: nil, key: "settings.language.system"),
        .init(code: "de", key: nil),
        .init(code: "en", key: nil),
        .init(code: "es", key: nil),
        .init(code: "fr", key: nil),
        .init(code: "pt-BR", key: nil),
        .init(code: "ja", key: nil),
        .init(code: "zh-Hans", key: nil),
        .init(code: "zh-Hant", key: nil),
        .init(code: "ko", key: nil),
    ]

    struct LanguageOption: Identifiable {
        let code: String?
        /// Key into the strings table for the "system language" entry; other
        /// languages use their own endonym as the display name.
        let key: String?

        var id: String { code ?? "system" }

        /// Display name: endonym, or the localized "System Language" label.
        var displayName: String {
            if let key {
                return L(key, "System Language")
            }
            return Self.endonyms[code!] ?? code!
        }

        private static let endonyms: [String: String] = [
            "de": "Deutsch",
            "en": "English",
            "es": "Español",
            "fr": "Français",
            "pt-BR": "Português (Brasil)",
            "ja": "日本語",
            "zh-Hans": "简体中文",
            "zh-Hant": "繁體中文",
            "ko": "한국어",
        ]
    }

    /// The active table; falls back to the English table, then to empty.
    private static var table: [String: String] = GeneratedStrings.tables["en"] ?? [:]

    /// The active language override; nil = system language.
    private static var activeOverride: String?

    /// Loads the string table for `code` (nil = system language).
    static func setLanguage(_ code: String?) {
        activeOverride = code
        let resolved = code ?? systemLanguageCode()
        table = GeneratedStrings.tables[resolved] ?? GeneratedStrings.tables["en"] ?? [:]
        DebugLog.log("localization: using \(resolved) (\(table.count) strings)")
    }

    /// Looks up `key`, returning `fallback` when missing.
    static func string(_ key: String, fallback: String) -> String {
        table[key] ?? fallback
    }

    // MARK: - System language resolution

    /// Picks the best shipped language from the user's preferred languages.
    static func systemLanguageCode() -> String {
        let available = Set(GeneratedStrings.tables.keys)
        for preferred in Locale.preferredLanguages {
            // Tag forms: "zh-Hans-CN", "pt-BR", "en-US", "de-DE", …
            let parts = preferred.split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }

            // Exact regional match first ("pt-BR", "zh-Hans").
            if parts.count > 1 {
                let twoPart = "\(base)-\(parts[1])"
                if available.contains(twoPart) { return twoPart }
            }

            // Chinese: pick the script from the tag; default to Simplified.
            if base == "zh" {
                let tag = preferred.lowercased()
                if tag.contains("hant") || tag.contains("tw") || tag.contains("hk") || tag.contains("mo") {
                    if available.contains("zh-Hant") { return "zh-Hant" }
                }
                if available.contains("zh-Hans") { return "zh-Hans" }
            }

            // Base language match ("en-US" → "en", "pt-PT" → "pt-BR").
            if available.contains(base) { return base }
            for candidate in available where candidate.hasPrefix(base + "-") {
                return candidate
            }
        }
        return "en"
    }
}

/// Shorthand used across the UI: `L("controls.play", "Play")`.
func L(_ key: String, _ fallback: String) -> String {
    Localization.string(key, fallback: fallback)
}
