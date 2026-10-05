import Foundation

/// Parses the date formats the media-server protocols report.
enum ISODateParser {

    /// RFC 1123 / asctime-style dates from WebDAV `getlastmodified`:
    /// "Mon, 02 Oct 2026 18:00:00 GMT".
    static func rfc1123(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text)
    }

    /// MLSD `modify` fact: "YYYYMMDDHHMMSS" (optionally with .sss fraction).
    static func mlsdModify(_ text: String) -> Date? {
        let digits = String(text.prefix(14))
        guard digits.count == 14, let stamp = Int(digits) else { return nil }
        var comps = DateComponents()
        comps.year = stamp / 1_000_000
        comps.month = (stamp / 10_000) % 100
        comps.day = (stamp / 100) % 100
        comps.hour = (stamp % 10_000) / 100
        comps.minute = stamp % 100
        comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    /// Classic unix LIST date columns: "Jan  1 12:00" (recent, no year) or
    /// "Jan  1  2024" (older than ~6 months). The year-less form is taken
    /// as the most recent matching date in the past.
    static func unixList(month: String, day: String, yearOrTime: String) -> Date? {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard let monthIndex = months.firstIndex(of: month) else { return nil }
        guard let day = Int(day) else { return nil }

        var comps = DateComponents()
        comps.month = monthIndex + 1
        comps.day = day

        if yearOrTime.contains(":") {
            // "12:00" — no year: assume the current year, and if that lands
            // in the future, step back one year (LIST omits the year for
            // files newer than ~6 months).
            let now = Calendar.current.dateComponents([.year], from: Date())
            comps.year = now.year
            var hour = 0, minute = 0
            let parts = yearOrTime.split(separator: ":")
            if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
                hour = h; minute = m
            }
            comps.hour = hour
            comps.minute = minute
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            guard var date = cal.date(from: comps) else { return nil }
            if date > Date() {
                comps.year = (now.year ?? 2026) - 1
                guard let back = cal.date(from: comps) else { return nil }
                date = back
            }
            return date
        } else if let year = Int(yearOrTime), year >= 1900 {
            comps.year = year
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            return cal.date(from: comps)
        }
        return nil
    }
}
