// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BrushLLMPlayer",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        // libmpv + FFmpeg xcframeworks (GPL build, matches the app's GPL-3.0 license)
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "BrushLLMPlayer",
            dependencies: [
                .product(name: "MPVKit-GPL", package: "MPVKit")
            ],
            path: "Sources/BrushLLMPlayer",
            // The .lproj strings files are the source of truth for
            // scripts/generate-localizable.sh, which compiles them into the
            // binary — they are not bundled as runtime resources.
            exclude: ["Resources"],
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5"]),
                // The video layer is CAOpenGLLayer-based (IINA's proven
                // architecture); OpenGL is deprecated on macOS but fully
                // functional. This define silences the API-wide deprecation
                // warnings, including CAOpenGLLayer's own.
                .unsafeFlags(["-Xcc", "-DGL_SILENCE_DEPRECATION"])
            ]
        )
    ]
)
