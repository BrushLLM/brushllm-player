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
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let digits = Array(parts[0].utf8)
        guard digits.count == 14, digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
        func number(_ range: Range<Int>) -> Int {
            digits[range].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        var fraction = 0.0
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Double("0." + parts[1]), value.isFinite else { return nil }
            fraction = value
        }
        var comps = DateComponents()
        comps.year = number(0..<4)
        comps.month = number(4..<6)
        comps.day = number(6..<8)
        comps.hour = number(8..<10)
        comps.minute = number(10..<12)
        comps.second = number(12..<14)
        guard (1...9999).contains(comps.year!), (1...12).contains(comps.month!),
              (1...31).contains(comps.day!), (0...23).contains(comps.hour!),
              (0...59).contains(comps.minute!), (0...59).contains(comps.second!) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: comps) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == comps.year, roundTrip.month == comps.month, roundTrip.day == comps.day,
              roundTrip.hour == comps.hour, roundTrip.minute == comps.minute, roundTrip.second == comps.second else { return nil }
        return date.addingTimeInterval(fraction)
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
