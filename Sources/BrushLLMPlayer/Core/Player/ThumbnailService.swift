import Foundation
import AVFoundation
import AppKit

/// Generates timeline thumbnails with AVAssetImageGenerator and caches them on
/// disk as JPEG (ImageIO encoding — MPVKit's FFmpeg has no encoders).
///
/// Generation runs on AVFoundation's own queues; the disk cache is keyed by
/// file path + size + mtime so stale caches are skipped.
actor ThumbnailService {

    /// Generates a single frame at an exact time position (for hover preview).
    /// Synchronous — call from a background queue. Returns nil on failure.
    nonisolated static func generateSingleFrame(from url: URL, at time: Double) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10) // 0.1s
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        var actualTime = CMTime.zero
        guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: &actualTime) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static let shared = ThumbnailService()

    struct CacheEntry: Codable {
        let time: Double
        let file: String
    }

    private var memoryCache: [String: [Double: NSImage]] = [:]
    private var inFlight: [String: Task<[Double: NSImage], Error>] = [:]
    private let cacheDirectory: URL

    private init() {
        let caches = (NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
                      ?? NSTemporaryDirectory()) + "/BrushLLM Player/thumbnails"
        try? FileManager.default.createDirectory(atPath: caches, withIntermediateDirectories: true)
        cacheDirectory = URL(fileURLWithPath: caches)
    }

    /// Returns thumbnails for a media URL, keyed by their time position.
    /// Returns nil when the media can't be previewed (e.g. live streams).
    func thumbnails(for url: URL, count: Int = 80) async throws -> [Double: NSImage] {
        // EDL files are virtual — generate from the underlying VOBs instead.
        if url.pathExtension.lowercased() == "edl" {
            let vobPaths = (try? String(contentsOf: url, encoding: .utf8))?
                .split(separator: "\n")
                .dropFirst() // skip the header
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) } ?? []
            if !vobPaths.isEmpty {
                // Cache key from the VOB list (not the temp EDL path)
                let cacheKey = vobPaths.map(\.path).joined(separator: "|")
                if let cached = memoryCache[cacheKey] {
                    return cached
                }
                let result = try await thumbnails(forFiles: vobPaths, count: count)
                memoryCache[cacheKey] = result
                return result
            }
        }
        return try await thumbnails(forSingle: url, count: count)
    }

    /// Generates thumbnails across multiple sequential files (EDL playback),
    /// keyed by position on the combined timeline.
    func thumbnails(forFiles urls: [URL], count: Int = 80) async throws -> [Double: NSImage] {
        // Get each file's duration
        var durations: [Double] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            var duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .invalid)
            if duration > 3600 {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                duration = Double(size) / (2.0 * 1024 * 1024)
            }
            durations.append(max(duration, 0))
        }
        let total = durations.reduce(0, +)
        guard total > 1 else { return [:] }

        // Generate thumbnails at evenly-spaced positions on the combined timeline
        var result: [Double: NSImage] = [:]
        let step = total / Double(count)
        for index in 0..<count {
            let timelinePos = Double(index) * step
            // Find which file this position falls in
            var fileIndex = 0
            var offset = timelinePos
            for (i, dur) in durations.enumerated() {
                if offset < dur {
                    fileIndex = i
                    break
                }
                offset -= dur
            }
            guard fileIndex < urls.count else { continue }

            // Generate the thumbnail
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: urls[fileIndex]))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 256)
            if let cgImage = try? await generator.image(at: CMTime(seconds: offset, preferredTimescale: 600)).image {
                result[timelinePos] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            if Task.isCancelled { break }
        }
        return result
    }

    /// Original single-file thumbnail generation.
    private func thumbnails(forSingle url: URL, count: Int = 80) async throws -> [Double: NSImage] {
        let key = cacheKey(for: url)
        if let cached = memoryCache[key] {
            return cached
        }
        if let inFlightTask = inFlight[key] {
            return try await inFlightTask.value
        }

        let task = Task<[Double: NSImage], Error> {
            try await generate(url: url, key: key, count: count)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await task.value
        memoryCache[key] = result
        return result
    }

    // MARK: - Generation

    private func generate(url: URL, key: String, count: Int) async throws -> [Double: NSImage] {
        // Try the disk cache first.
        if let disk = loadFromDisk(key: key) {
            return disk
        }

        let asset = AVURLAsset(url: url)
        let duration = try await loadDuration(asset: asset)
        guard duration > 0.5 else { return [:] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        var result: [Double: NSImage] = [:]
        let step = duration / Double(count)
        for index in 0..<count {
            let time = min(Double(index) * step, duration - 0.05)
            if let cgImage = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                // HDR / wide-gamut sources render black in a non-EDR SwiftUI
                // context — force sRGB.
                let safe = Self.convertToSRGB(cgImage) ?? cgImage
                result[time] = NSImage(cgImage: safe, size: NSSize(width: safe.width, height: safe.height))
            }
            if Task.isCancelled { break }
        }
        if !result.isEmpty {
            saveToDisk(key: key, thumbnails: result)
        }
        return result
    }

    private func loadDuration(asset: AVURLAsset) async throws -> Double {
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    /// Redraws a CGImage into an 8-bit sRGB bitmap.
    private static func convertToSRGB(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Disk cache

    private func cacheKey(for url: URL) -> String {
        let path = url.isFileURL ? url.path : url.absoluteString
        var attributes: String = ""
        if url.isFileURL {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs?[.size] as? Int ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            attributes = "\(size)-\(Int(mtime))"
        }
        let raw = path + "|" + attributes
        return raw.data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "") ?? "default"
    }

    private func diskURL(key: String, time: Double) -> URL {
        cacheDirectory.appendingPathComponent("\(key)-\(Int(time * 1000)).jpg")
    }

    private func loadFromDisk(key: String) -> [Double: NSImage]? {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        let prefix = key + "-"
        var result: [Double: NSImage] = [:]
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let timePart = stem.dropFirst(prefix.count).split(separator: "-").last,
                  let milliseconds = Int(timePart) else { continue }
            guard let image = NSImage(contentsOf: file) else { continue }
            result[Double(milliseconds) / 1000] = image
        }
        return result.isEmpty ? nil : result
    }

    private func saveToDisk(key: String, thumbnails: [Double: NSImage]) {
        for (time, image) in thumbnails {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { continue }
            let url = diskURL(key: key, time: time)
            try? jpeg.write(to: url, options: .atomic)
        }
    }
}
