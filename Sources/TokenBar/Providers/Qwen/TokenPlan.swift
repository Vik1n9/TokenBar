import Foundation

/// Raw payload returned by `/tokenplan/personal/api/v2/usage`.
struct UsagePayload: Decodable {
    let per1WeekResetTime: Double?
    let per1WeekPercentage: Double?
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
    var usedFraction: Double?      // 0...1, share of the 7-day allowance already spent
    var resetTime: Date?
    var specCode: String?
    var status: String?
    var remainingDays: Int?
    var endTime: Date?
    var autoRenew: Bool?
    var fetchedAt: Date

    /// Percentage of the 7-day allowance still available.
    var remainingPercent: Double? {
        guard let usedFraction else { return nil }
        return max(0, min(1, 1 - usedFraction)) * 100
    }

    init(bridge: BridgeResult, fetchedAt: Date = Date()) {
        self.usedFraction = bridge.usage?.per1WeekPercentage
        self.resetTime = Self.date(fromEpochMillis: bridge.usage?.per1WeekResetTime)
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
