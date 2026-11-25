import Foundation

func playbackClock(_ seconds: Double) -> String {
    guard seconds >= 0, let total = Int(exactly: seconds.rounded(.towardZero)) else { return "0:00" }
    let hours = total / 3600
    let minutes = total / 60 % 60
    let remainder = total % 60
    if hours > 0 {
        return "\(hours):\(padded(minutes)):\(padded(remainder))"
    }
    return "\(minutes):\(padded(remainder))"
}

private func padded(_ value: Int) -> String {
    value < 10 ? "0\(value)" : String(value)
}
