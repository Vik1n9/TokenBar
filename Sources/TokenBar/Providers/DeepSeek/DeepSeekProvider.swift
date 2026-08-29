import AppKit

/// DeepSeek API account, read with a bearer key.
///
/// Balance comes from the documented `/user/balance`. Spending is harder: there
/// is no usage endpoint in the published reference. This provider tries the
/// undocumented `/v1/usage` once and remembers the answer; when the account does
/// not have it, spend figures come from `BalanceLedger` and are labelled as
/// estimates.
@MainActor
final class DeepSeekProvider: Provider {
    let id = "deepseek"
    let glyph = "D"
    let displayName = "DeepSeek API"
    var authKind: AuthKind { .apiKey }

    static let keychainAccount = "deepseek-api-key"

    enum DisplayMode: Int {
        case balanceOnly = 0
        case balanceAndToday = 1
    }

    private let client = APIClient()
    private let keychain = KeychainStore(account: DeepSeekProvider.keychainAccount)
    private let ledger = BalanceLedger()
    private let notifier = Notifier()

    /// Set by the shell: asks for an immediate refresh after a settings change.
    var onRefreshRequested: (() -> Void)?

    /// nil = not probed yet; the probe runs once and the answer is remembered
    /// so a 404-ing account is not re-asked on every poll.
    private var usageEndpointWorks: Bool? {
        get { UserDefaults.standard.object(forKey: "deepseek.usageWorks") as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: "deepseek.usageWorks") }
    }

    var apiKey: String? { keychain.load() }
    var isConfigured: Bool { !(apiKey ?? "").isEmpty }

    init() {
        notifier.requestAuthorizationIfNeeded()
    }

    // MARK: - Settings-backed preferences

    var preferredCurrency: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: "deepseek.currency") ?? ""
            return stored.isEmpty ? nil : stored
        }
        set { UserDefaults.standard.set(newValue ?? "", forKey: "deepseek.currency") }
    }

    var lowBalanceThreshold: Decimal {
        get {
            let stored = UserDefaults.standard.string(forKey: "deepseek.threshold") ?? ""
            if stored.isEmpty { return defaultThreshold(for: preferredCurrency ?? "CNY") }
            return Money.parse(stored)
        }
        set { UserDefaults.standard.set(Money.amount(newValue), forKey: "deepseek.threshold") }
    }

    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: UserDefaults.standard.integer(forKey: "deepseek.displayMode")) ?? .balanceOnly }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "deepseek.displayMode") }
    }

    private func defaultThreshold(for currency: String) -> Decimal {
        Money.normalize(currency) == "USD" ? 2 : 10
    }

    // MARK: - Fetch

    func fetch() async throws -> ProviderSnapshot {
        guard let key = apiKey, !key.isEmpty else { throw ProviderError.needsAuth }

        let balance = try await client.fetchBalance(apiKey: key)
        let now = Date()
        ledger.record(balance, at: now)

        guard let wallet = balance.preferred(preferredCurrency) else {
            return ProviderSnapshot(barText: "—",
                                    severity: .warning,
                                    rows: [.notice("Account has no wallet")],
                                    fetchedAt: now)
        }
        let currency = Money.normalize(wallet.currency).isEmpty
            ? wallet.currency.uppercased()
            : Money.normalize(wallet.currency)

        notifier.evaluate(balance: wallet.total,
                          currency: currency,
                          threshold: lowBalanceThreshold,
                          isAvailableForUse: balance.isAvailable)

        let usage = await fetchUsageIfAvailable(key: key, now: now)

        return ProviderSnapshot(barText: barText(balance: balance, wallet: wallet, currency: currency, usage: usage),
                                severity: severity(balance: balance, wallet: wallet),
                                rows: Self.rows(balance: balance,
                                                preferredCurrency: preferredCurrency,
                                                threshold: lowBalanceThreshold,
                                                now: now),
                                fetchedAt: now)
    }

    /// Best-effort. A 404 means this account has no usage endpoint, which is a
    /// normal state, not an error to show the user.
    private func fetchUsageIfAvailable(key: String, now: Date) async -> UsageResponse? {
        if usageEndpointWorks == false { return nil }
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        do {
            let usage = try await client.fetchUsage(apiKey: key, from: start, to: now)
            usageEndpointWorks = true
            return usage
        } catch APIError.usageEndpointUnavailable {
            usageEndpointWorks = false
            return nil
        } catch {
            // A transient failure should not disable the endpoint permanently.
            return nil
        }
    }

    func signOut() async {
        keychain.delete()
    }

    /// Validates a candidate key against the live endpoint without storing it,
    /// then saves it only if the provider accepted it.
    func validateAndSave(_ candidate: String) async throws {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.noAPIKey }
        _ = try await client.fetchBalance(apiKey: trimmed)
        try keychain.save(trimmed)
    }

    func extraMenuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Open Usage Page", action: #selector(openUsagePage), keyEquivalent: "")
        item.target = self
        return [item]
    }

    @objc private func openUsagePage() {
        guard let url = URL(string: "https://platform.deepseek.com/usage") else { return }
        NSWorkspace.shared.open(url)
    }

    func settingsPane() -> NSView {
        DeepSeekSettingsPane(provider: self)
    }

    // MARK: - Display

    private func severity(balance: BalanceResponse, wallet: BalanceInfo) -> Severity {
        if !balance.isAvailable { return .warning }
        return wallet.total < lowBalanceThreshold ? .warning : .normal
    }

    private func barText(balance: BalanceResponse, wallet: BalanceInfo, currency: String, usage: UsageResponse?) -> String {
        var text = balance.display(preferring: preferredCurrency)
        if displayMode == .balanceAndToday {
            let today = spendToday(currency: currency, usage: usage)
            text += " · " + Money.format(today, currency: currency)
        }
        return text
    }

    /// The usage endpoint is authoritative when the account has it; the ledger
    /// is the fallback. Today's slice of a month-to-date usage response is not
    /// available per-day for every account shape, so the ledger still answers
    /// "today" unless the usage records carry dates.
    private func spendToday(currency: String, usage: UsageResponse?) -> Decimal {
        if let usage, let today = usageSpend(usage, currency: currency, on: Date()) { return today }
        return ledger.spendToday(currency: currency)
    }

    private func usageSpend(_ usage: UsageResponse, currency: String, on day: Date) -> Decimal? {
        let key = Formatters.apiDate.string(from: day)
        let matching = usage.data.filter { $0.date == key }
        guard !matching.isEmpty else { return nil }
        var total = Decimal.zero
        var sawCost = false
        for record in matching {
            for (recordCurrency, amount) in record.costByCurrency
            where Money.normalize(recordCurrency) == Money.normalize(currency) {
                total += amount
                sawCost = true
            }
        }
        return sawCost ? total : nil
    }

    /// The drop-down answers two questions: how much credit is left, and which
    /// rate band is running. Spend history, runway and token counts are all
    /// estimates that made the menu long and hard to read; they are dropped.
    /// Rows that are not routine — a wallet that cannot serve calls, a second
    /// currency — still appear, because hiding those would hide real money.
    nonisolated static func rows(balance: BalanceResponse,
                                 preferredCurrency: String?,
                                 threshold: Decimal? = nil,
                                 now: Date = Date()) -> [MenuRow] {
        // A balance has no full mark to measure against, so it carries no bar;
        // the low-balance threshold is what turns the number red instead.
        let wallet = balance.preferred(preferredCurrency)
        let isLow: Bool
        if !balance.isAvailable {
            isLow = true
        } else if let threshold, threshold > 0, let wallet {
            isLow = wallet.total < threshold
        } else {
            isLow = false
        }
        var rows: [MenuRow] = [.metric("Balance",
                                       balance.display(preferring: preferredCurrency),
                                       isWarning: isLow)]

        if let wallet, balance.isMultiCurrency {
            // Wallets are shown side by side; they are never summed. An
            // unrecognized code falls back to itself, so two unknown currencies
            // do not collapse into one row.
            func code(_ currency: String) -> String {
                let iso = Money.normalize(currency)
                return iso.isEmpty ? currency.uppercased() : iso
            }
            let shown = code(wallet.currency)
            for info in balance.balanceInfos where code(info.currency) != shown {
                rows.append(.metric("\(code(info.currency)) wallet",
                                    Money.format(info.total, currency: info.currency)))
            }
        }

        if !balance.isAvailable {
            rows.append(.notice("Account cannot serve API calls"))
        }

        rows.append(.caption(PeakSchedule.summary(at: now)))
        return rows
    }
}
