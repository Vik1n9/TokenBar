import Foundation

/// One quota window from the usage payload, e.g. `per1MonthPercentage` +
/// `per1MonthResetTime`.
struct UsageWindow: Equatable {
    enum Unit: String, CaseIterable { case Hour, Day, Week, Month }

    let count: Int
    let unit: Unit
    var usedFraction: Double?      // 0...1, share of the allowance already spent
    var resetTime: Double?         // epoch millis

    /// Human name for the window: "Monthly", "7-day", "5-hour".
    var label: String {
        switch (count, unit) {
        case (1, .Month): return "Monthly"
        case (1, .Week): return "7-day"
        case (1, .Day): return "Daily"
        case (let n, .Week): return "\(n * 7)-day"
        case (let n, .Month): return "\(n)-month"
        case (let n, _): return "\(n)-\(unit.rawValue.lowercased())"
        }
    }

    /// Rough length, only used to order windows shortest first.
    var hours: Int {
        switch unit {
        case .Hour: return count
        case .Day: return count * 24
        case .Week: return count * 24 * 7
        case .Month: return count * 24 * 30
        }
    }
}

/// Raw payload returned by `/tokenplan/personal/api/v2/usage`.
///
/// The window has changed under us before (`per1Week*` became `per1Month*`), so
/// every `per<N><Unit>Percentage` / `per<N><Unit>ResetTime` pair is picked up
/// rather than one hard-coded key.
struct UsagePayload: Decodable {
    let windows: [UsageWindow]      // shortest first

    private struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var byKey: [String: UsageWindow] = [:]
        for key in container.allKeys {
            guard let parsed = Self.parse(key.stringValue),
                  let value = try? container.decode(Double.self, forKey: key) else { continue }
            let id = "\(parsed.count)\(parsed.unit.rawValue)"
            var window = byKey[id] ?? UsageWindow(count: parsed.count, unit: parsed.unit)
            if parsed.isReset { window.resetTime = value } else { window.usedFraction = value }
            byKey[id] = window
        }
        windows = byKey.values.sorted { $0.hours < $1.hours }
    }

    /// `per5HourPercentage` -> (5, .Hour, false); anything else -> nil.
    static func parse(_ key: String) -> (count: Int, unit: UsageWindow.Unit, isReset: Bool)? {
        guard key.hasPrefix("per") else { return nil }
        var rest = Substring(key.dropFirst(3))
        let isReset: Bool
        if rest.hasSuffix("Percentage") { isReset = false; rest = rest.dropLast("Percentage".count) }
        else if rest.hasSuffix("ResetTime") { isReset = true; rest = rest.dropLast("ResetTime".count) }
        else { return nil }
        let digits = rest.prefix { $0.isNumber }
        guard let count = Int(digits), count > 0,
              let unit = UsageWindow.Unit(rawValue: String(rest.dropFirst(digits.count))) else { return nil }
        return (count, unit, isReset)
    }
}

/// Raw payload returned by `/tokenplan/personal/api/v2/subscription`.
struct SubscriptionPayload: Decodable {
    let instanceCode: String?
    let specCode: String?
    let remainingDays: Int?
    let startTime: Double?
    let endTime: Double?
    let autoRenewFlag: Bool?
    let status: String?
}

/// Envelope produced by the JavaScript bridge running inside the console page.
struct BridgeResult: Decodable {
    let loggedIn: Bool
    let usage: UsagePayload?
    let subscription: SubscriptionPayload?
    let error: String?
}

/// One consistent reading of the token plan, ready for display.
struct PlanSnapshot {
    var windows: [UsageWindow]
    var specCode: String?
    var status: String?
    var remainingDays: Int?
    var endTime: Date?
    var autoRenew: Bool?
    var fetchedAt: Date

    /// The window with the least left, which is the one that will stop
    /// requests first; ties go to the shorter window.
    var binding: UsageWindow? {
        windows.filter { $0.usedFraction != nil }
            .min { Self.remainingPercent($0)! < Self.remainingPercent($1)! }
            ?? windows.first
    }

    /// Percentage of the binding window's allowance still available.
    var remainingPercent: Double? { binding.flatMap(Self.remainingPercent) }
    var resetTime: Date? { binding.flatMap(Self.resetDate) }

    static func remainingPercent(_ window: UsageWindow) -> Double? {
        guard let used = window.usedFraction else { return nil }
        return max(0, min(1, 1 - used)) * 100
    }

    static func resetDate(_ window: UsageWindow) -> Date? {
        date(fromEpochMillis: window.resetTime)
    }

    init(bridge: BridgeResult, fetchedAt: Date = Date()) {
        self.windows = bridge.usage?.windows ?? []
        self.specCode = bridge.subscription?.specCode
        self.status = bridge.subscription?.status
        self.remainingDays = bridge.subscription?.remainingDays
        self.endTime = Self.date(fromEpochMillis: bridge.subscription?.endTime)
        self.autoRenew = bridge.subscription?.autoRenewFlag
        self.fetchedAt = fetchedAt
    }

    private static func date(fromEpochMillis millis: Double?) -> Date? {
        guard let millis, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
