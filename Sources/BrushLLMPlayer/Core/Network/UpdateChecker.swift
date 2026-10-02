import Foundation

/// Checks GitHub for a newer release. Manual-only by design: no
/// launch-time checks and no downloads — the user clicks the button and,
/// when an update exists, the release page opens in the default browser.
enum UpdateChecker {

    /// Outcome of a check.
    enum Result {
        /// The local version is >= the latest published release.
        case upToDate(latest: String)
        /// A newer release is published.
        case available(latest: String)
        /// Network / HTTP / parsing failure. The detail goes to the debug
        /// log; the card shows a generic localized message.
        case failed(detail: String)
    }

    static let releasePageURL = URL(string: "https://github.com/BrushLLM/brushllm-player/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/BrushLLM/brushllm-player/releases/latest")!

    /// The bundle's marketing version, e.g. "0.0.2" — same source as the
    /// installer, so the two can never disagree.
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Fetches the latest release tag and compares it against the local
    /// version. Runs on the caller's async context; UI state updates are
    /// the caller's job.
    static func check() async -> Result {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("BrushLLMPlayer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(detail: "not an HTTP response")
            }
            guard http.statusCode == 200 else {
                return .failed(detail: "HTTP \(http.statusCode)")
            }
            guard let tag = (try? JSONDecoder().decode(Release.self, from: data))?.tagName else {
                return .failed(detail: "invalid response body")
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DebugLog.log("update: local \(currentVersion), latest \(latest)")
            return compare(currentVersion, latest) == .orderedAscending
                ? .available(latest: latest)
                : .upToDate(latest: latest)
        } catch {
            return .failed(detail: error.localizedDescription)
        }
    }

    private struct Release: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
    }

    /// Numeric dotted-version comparison — "0.0.10" > "0.0.9", unlike a
    /// plain string compare. Missing segments count as zero.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }
}
