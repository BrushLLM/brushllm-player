import Foundation
import UniformTypeIdentifiers

/// Uniform type identifiers accepted by the player.
enum MediaTypes {
    /// Extensions the browser treats as playable when adding a folder's
    /// contents to the playlist. Single source for this decision.
    static let playableExtensions: Set<String> = [
        // Video
        "mkv", "mp4", "m4v", "avi", "mov", "webm", "flv", "wmv", "mpg", "mpeg",
        "ts", "m2ts", "mts", "vob", "3gp", "ogv", "rmvb", "iso", "iso9660", "m3u8",
        // Audio
        "mp3", "flac", "wav", "aac", "ogg", "opus", "m4a", "wma", "ape", "wv", "aiff", "alac",
    ]

    /// The packaging script copies the shared format list into these declarations.
    private static let declarations = Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations")
        as? [[String: Any]] ?? []

    private static func extensions(in declaration: [String: Any]) -> [String] {
        let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
        return tags?["public.filename-extension"] as? [String] ?? []
    }

    static let associationExtensions = Array(Set(declarations.flatMap(extensions))).sorted()

    static let associationTypes: [UTType] = {
        let families: [String: UTType] = [
            "dev.brushllm.video": .audiovisualContent,
            "dev.brushllm.audio": .audio,
            "dev.brushllm.playlist": .playlist,
            "dev.brushllm.disc": .diskImage,
        ]
        var seen = Set<UTType>()
        return declarations.flatMap { declaration -> [UTType] in
            guard let identifier = declaration["UTTypeIdentifier"] as? String,
                  let family = families[identifier],
                  let fallback = UTType(identifier) else { return [] }
            let preferred = extensions(in: declaration).compactMap { suffix -> UTType? in
                if let type = UTType(filenameExtension: suffix), !type.isDynamic, type.conforms(to: family) {
                    return type
                }
                // An extension may also identify a non-media type, such as .spx system reports.
                return UTType.types(tag: suffix, tagClass: .filenameExtension, conformingTo: family)
                    .first { !$0.isDynamic && $0 != fallback } ?? fallback
            }
            return (preferred + [fallback]).filter { seen.insert($0).inserted }
        }
    }()

    static func isDiscImage(_ path: String) -> Bool {
        let suffix = (path as NSString).pathExtension.lowercased()
        return suffix == "iso" || suffix == "iso9660"
    }

    static var all: [UTType] {
        // SwiftPM development runs have no packaged Info.plist.
        let types = associationTypes.isEmpty
            ? playableExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
            : associationTypes
        return [.movie, .video, .audio] + types
    }
}
