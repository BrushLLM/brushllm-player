import Foundation

enum URLPrivacy {
    static func redact(_ message: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>\"']+"#) else {
            return message
        }
        var result = message
        let matches = expression.matches(in: message, range: NSRange(message.startIndex..., in: message))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range])
            guard var url = URLComponents(string: raw) else {
                result.replaceSubrange(range, with: "[redacted URL]")
                continue
            }
            url.user = nil
            url.password = nil
            url.query = nil
            url.fragment = nil
            result.replaceSubrange(range, with: url.string ?? "[redacted URL]")
        }
        return result
    }
}

struct SubtitleColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init?(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6 || cleaned.count == 8,
              cleaned.allSatisfy({ $0.isHexDigit }), let value = UInt64(cleaned, radix: 16) else { return nil }
        let rgb = cleaned.count == 8 ? value >> 8 : value
        red = Double((rgb >> 16) & 255) / 255
        green = Double((rgb >> 8) & 255) / 255
        blue = Double(rgb & 255) / 255
        alpha = cleaned.count == 8 ? Double(value & 255) / 255 : 1
    }

    var mpvValue: String {
        String(format: "#%02X%02X%02X%02X", Int((alpha * 255).rounded()),
               Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}
