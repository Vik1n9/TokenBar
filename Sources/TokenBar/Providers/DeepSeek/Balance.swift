import Foundation

/// Response of `GET /user/balance`. Every amount arrives as a string, so it is
/// parsed into `Decimal` rather than `Double` — these are money values and a
/// binary float would quietly drift on the cent.
struct BalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

struct BalanceInfo: Decodable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String
    let toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }

    var total: Decimal { Money.parse(totalBalance) }
    var granted: Decimal { Money.parse(grantedBalance) }
    var toppedUp: Decimal { Money.parse(toppedUpBalance) }
}

/// Currency handling for wallet balances.
///
/// The rules here follow DeepSeek-Reasonix's `internal/billing/balance.go`
/// (MIT, see NOTICE): wallets in different currencies are never converted and
/// never added together. There is no exchange rate anywhere in this app; when a
/// requested currency is missing, the real one is shown with its ISO code rather
/// than a converted number.
enum Money {
    /// Parses a provider amount string. POSIX locale, because the API always
    /// emits `.` as the decimal separator regardless of the user's region.
    static func parse(_ raw: String) -> Decimal {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) ?? .zero
    }

    /// Maps the spellings a provider might use onto an ISO code. Returns an
    /// empty string for anything unrecognized, so callers can tell "not a
    /// currency we know" from "CNY".
    static func normalize(_ currency: String) -> String {
        switch currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "CNY", "RMB", "CNH", "¥", "￥": return "CNY"
        case "USD", "$", "US$": return "USD"
        default: return ""
        }
    }

    /// Compact symbol for an ISO code. An unknown code passes through with a
    /// trailing space, so it reads as `XYZ 12.00`.
    static func symbol(_ currency: String) -> String {
        switch currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        default:
            let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return code.isEmpty ? "" : code + " "
        }
    }

    /// Two fixed decimals, truncated rather than rounded up, POSIX-formatted.
    /// Truncating keeps the app from ever showing more money than the account has.
    static func amount(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .down
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0.00"
    }

    /// `¥110.00`, `$12.34`, `XYZ 5.00`.
    static func format(_ value: Decimal, currency: String) -> String {
        symbol(currency) + amount(value)
    }
}

extension BalanceResponse {
    /// Distinct ISO currencies present in the wallet, in stable order.
    var currencies: [String] {
        var seen = Set<String>()
        for info in balanceInfos {
            let code = Money.normalize(info.currency)
            seen.insert(code.isEmpty ? info.currency.uppercased() : code)
        }
        return seen.sorted()
    }

    var isMultiCurrency: Bool { currencies.count > 1 }

    /// The single usable wallet currency, if there is exactly one.
    var primaryCurrency: String? {
        guard currencies.count == 1, let only = currencies.first else { return nil }
        return (only == "CNY" || only == "USD") ? only : nil
    }

    /// Picks the wallet to show. Preference wins when present; otherwise the
    /// CNY-first fallback, matching what the provider's own console shows.
    func preferred(_ currency: String?) -> BalanceInfo? {
        if let currency {
            let wanted = Money.normalize(currency)
            if !wanted.isEmpty,
               let match = balanceInfos.first(where: { Money.normalize($0.currency) == wanted }) {
                return match
            }
        }
        if let cny = balanceInfos.first(where: { Money.normalize($0.currency) == "CNY" }) {
            return cny
        }
        return balanceInfos.first
    }

    /// Renders the preferred wallet. When the requested currency is absent, the
    /// real currency is shown prefixed with its ISO code (`CNY ¥70.16`) so the
    /// mismatch is visible instead of silently converted away.
    func display(preferring currency: String?) -> String {
        guard let info = preferred(currency) else { return "—" }
        let shown = Money.format(info.total, currency: info.currency)
        let actual = Money.normalize(info.currency)
        let wanted = currency.map(Money.normalize) ?? ""
        if !wanted.isEmpty, !actual.isEmpty, actual != wanted {
            return actual + " " + shown
        }
        return shown
    }
}
