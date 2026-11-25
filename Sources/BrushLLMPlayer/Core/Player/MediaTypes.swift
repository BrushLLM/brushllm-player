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

    struct FileAssociation {
        let type: UTType
        let extensions: [String]
    }

    static let associations: [FileAssociation] = {
        let families: [String: UTType] = [
            "dev.brushllm.video": .audiovisualContent,
            "dev.brushllm.audio": .audio,
            "dev.brushllm.playlist": .playlist,
            "dev.brushllm.iso.disc": .diskImage,
        ]
        var extensionsByType: [UTType: Set<String>] = [:]
        for declaration in declarations {
            guard let identifier = declaration["UTTypeIdentifier"] as? String,
                  let family = families[identifier],
                  let fallback = UTType(identifier) else { continue }
            for suffix in extensions(in: declaration) {
                let contentType: UTType
                if let type = UTType(filenameExtension: suffix), !type.isDynamic,
                   type.conforms(to: family), type.conforms(to: .data) {
                    contentType = type
                } else {
                    // An extension may also identify a non-media type, such as .spx system reports.
                    contentType = UTType.types(tag: suffix, tagClass: .filenameExtension, conformingTo: family)
                        .first { !$0.isDynamic && $0 != fallback && $0.conforms(to: .data) } ?? fallback
                }
                extensionsByType[contentType, default: []].insert(suffix)
            }
        }
        return extensionsByType
            .map { FileAssociation(type: $0.key, extensions: $0.value.sorted()) }
            .sorted { $0.type.identifier < $1.type.identifier }
    }()

    static func isDiscImage(_ path: String) -> Bool {
        let suffix = (path as NSString).pathExtension.lowercased()
        return suffix == "iso" || suffix == "iso9660"
    }

    static var all: [UTType] {
        // SwiftPM development runs have no packaged Info.plist.
        let types = associations.isEmpty
            ? playableExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
            : associations.map(\.type)
        return [.movie, .video, .audio] + types
    }
}
