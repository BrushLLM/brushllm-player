import Foundation

/// One entry of mpv's `track-list`: an audio, video or subtitle track.
struct TrackInfo: Identifiable, Equatable {
    enum Kind: String {
        case audio
        case video
        case sub
    }

    /// mpv track ID — the value `aid`/`vid`/`sid` accept.
    let id: Int
    let kind: Kind
    let title: String?
    let language: String?
    let codec: String?
    let isDefault: Bool
    let isSelected: Bool
    let isForced: Bool
    /// True for tracks loaded from external files (sub-add / sub-files).
    let isExternal: Bool
    /// The full path of the external file, when `isExternal`.
    let externalFilename: String?

    /// Human-readable label for menus and panels.
    var label: String {
        var parts: [String] = []
        if let language, !language.isEmpty {
            parts.append(LanguageNames.displayName(forCode: language))
        }
        if isExternal, let externalFilename,
           let name = URL(fileURLWithPath: externalFilename).lastPathComponent.removingPercentEncoding,
           !name.isEmpty {
            // mpv's title for external tracks is inconsistent (sometimes just
            // the format, e.g. "srt") — the real file name always identifies
            // the track better.
            parts.append(name)
        } else if let title, !title.isEmpty {
            parts.append(title)
        }
        if parts.isEmpty {
            parts.append("\(kind.rawValue) \(id)")
        }
        return parts.joined(separator: " · ")
    }

    static func from(mpvMap map: [String: Any]) -> TrackInfo? {
        guard let id = map["id"] as? Int,
              let typeString = map["type"] as? String,
              let kind = Kind(rawValue: typeString) else { return nil }
        return TrackInfo(
            id: id,
            kind: kind,
            title: map["title"] as? String,
            language: map["lang"] as? String,
            codec: map["codec"] as? String,
            isDefault: (map["default"] as? Bool) ?? false,
            isSelected: (map["selected"] as? Bool) ?? false,
            isForced: (map["forced"] as? Bool) ?? false,
            isExternal: (map["external"] as? Bool) ?? false,
            externalFilename: map["external-filename"] as? String
        )
    }
}

/// One entry of mpv's `playlist`.
struct PlaylistItem: Identifiable, Equatable {
    /// mpv playlist entry ID (stable across reorders, unlike the index).
    let id: Int
    let filename: String
    let title: String?
    let isCurrent: Bool
    let isPlaying: Bool

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return (filename as NSString).lastPathComponent
    }

    static func from(mpvMap map: [String: Any]) -> PlaylistItem? {
        guard let id = map["id"] as? Int,
              let filename = map["filename"] as? String else { return nil }
        return PlaylistItem(
            id: id,
            filename: filename,
            title: map["title"] as? String,
            isCurrent: (map["current"] as? Bool) ?? false,
            isPlaying: (map["playing"] as? Bool) ?? false
        )
    }
}

/// One entry of mpv's `chapter-list`.
struct ChapterInfo: Identifiable, Equatable {
    let index: Int
    let title: String
    let startTime: Double

    var id: Int { index }

    static func from(mpvMap map: [String: Any], index: Int) -> ChapterInfo? {
        guard map["time"] != nil else { return nil }
        let time = map["time"] as? Double ?? 0
        let title = (map["title"] as? String) ?? String(format: "Chapter %d", index + 1)
        return ChapterInfo(index: index, title: title, startTime: time)
    }
}

/// Loop mode for playback, surfaced in UI and menus.
enum LoopMode: String, CaseIterable, Identifiable {
    case off
    case file
    case playlist

    var id: String { rawValue }
}

/// Display names for ISO 639 language codes, used in track labels.
enum LanguageNames {
    private static let known: [String: String] = [
        "zh": "中文", "chi": "中文", "zho": "中文",
        "en": "English", "eng": "English",
        "ja": "日本語", "jpn": "日本語",
        "ko": "한국어", "kor": "한국어",
        "de": "Deutsch", "ger": "Deutsch", "deu": "Deutsch",
        "es": "Español", "spa": "Español",
        "fr": "Français", "fre": "Français", "fra": "Français",
        "pt": "Português", "por": "Português",
        "pt-BR": "Português (Brasil)", "pb": "Português (Brasil)",
        "ru": "Русский", "rus": "Русский",
        "it": "Italiano", "ita": "Italiano",
        "th": "ไทย", "tha": "ไทย",
        "vi": "Tiếng Việt", "vie": "Tiếng Việt",
        "ar": "العربية", "ara": "العربية",
        "hi": "हिन्दी", "hin": "हिन्दी",
        "und": "—",
    ]

    static func displayName(forCode code: String) -> String {
        known[code] ?? code
    }
}
