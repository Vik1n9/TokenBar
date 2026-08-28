import Foundation

/// Peak and off-peak windows for DeepSeek's scheduled pricing.
///
/// Per the published pricing page: peak hours are 01:00–04:00 and 06:00–10:00
/// UTC, Monday through Friday; everything else is off-peak and costs half.
/// Intervals are left-closed / right-open, so 04:00:00 UTC is already off-peak.
enum RateBand {
    case peak
    case offPeak

    var label: String {
        switch self {
        case .peak: return "Peak"
        case .offPeak: return "Off-peak (50% off)"
        }
    }
}

enum PeakSchedule {
    /// Peak windows as [start, end) hour pairs in UTC.
    private static let windows: [(start: Int, end: Int)] = [(1, 4), (6, 10)]

    private static var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func band(at date: Date) -> RateBand {
        let parts = utc.dateComponents([.weekday, .hour], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour else { return .offPeak }
        // Calendar weekday: 1 = Sunday … 7 = Saturday.
        guard (2...6).contains(weekday) else { return .offPeak }
        return windows.contains { hour >= $0.start && hour < $0.end } ? .peak : .offPeak
    }

    /// When the band next flips. Scans hour boundaries, which is where every
    /// transition sits; capped at a week so a bad calendar can never spin.
    static func nextTransition(after date: Date) -> Date? {
        let current = band(at: date)
        guard var cursor = utc.nextDate(after: date,
                                        matching: DateComponents(minute: 0, second: 0),
                                        matchingPolicy: .nextTime)
        else { return nil }

        let limit = date.addingTimeInterval(7 * 24 * 3600)
        while cursor <= limit {
            if band(at: cursor) != current { return cursor }
            cursor = cursor.addingTimeInterval(3600)
        }
        return nil
    }

    /// `Off-peak (50% off) · peak in 2h` — nil when no transition is in range.
    static func summary(at date: Date = Date()) -> String {
        let current = band(at: date)
        guard let next = nextTransition(after: date) else { return current.label }
        let upcoming = current == .peak ? "off-peak" : "peak"
        return "\(current.label) · \(upcoming) in \(Formatters.countdown(to: next, from: date))"
    }
}
