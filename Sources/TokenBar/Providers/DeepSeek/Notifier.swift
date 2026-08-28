import Foundation
import UserNotifications

/// Low-balance alerts, with hysteresis so a balance hovering at the threshold
/// does not notify on every poll.
///
/// Rearming needs the balance back above 1.2× the threshold, not merely above
/// it: a wallet sitting exactly at the line would otherwise flip on and off.
@MainActor
final class Notifier {
    private static let armedKey = "deepseek.lowBalanceArmed"
    private static let unavailableArmedKey = "deepseek.unavailableArmed"
    /// Parsed from a string: a `Decimal` written as a float literal is built
    /// from a binary `Double` and carries drift.
    private static let rearmFactor = Money.parse("1.2")

    /// Notifications need a real bundle; `--self-check` runs the bare binary.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private var lowBalanceArmed: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Self.armedKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Self.armedKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.armedKey) }
    }

    private var unavailableArmed: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Self.unavailableArmedKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Self.unavailableArmedKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.unavailableArmedKey) }
    }

    func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Call once per poll with the wallet the menu bar is showing.
    func evaluate(balance: Decimal, currency: String, threshold: Decimal, isAvailableForUse: Bool) {
        if isAvailableForUse {
            unavailableArmed = true
        } else if unavailableArmed {
            unavailableArmed = false
            post(title: "API balance exhausted",
                 body: "The account can no longer serve API calls.")
        }

        guard threshold > 0 else { return }
        if balance < threshold {
            if lowBalanceArmed {
                lowBalanceArmed = false
                post(title: "Low API balance",
                     body: "\(Money.format(balance, currency: currency)) left, below your \(Money.format(threshold, currency: currency)) threshold.")
            }
        } else if balance >= threshold * Self.rearmFactor {
            lowBalanceArmed = true
        }
    }

    private func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
