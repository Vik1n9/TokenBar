import Foundation

/// One wallet reading, kept per currency so the next poll can be differenced
/// against it.
struct BalanceSample: Codable, Equatable {
    let at: Date
    let currency: String
    let total: Decimal
    let granted: Decimal
    let toppedUp: Decimal

    init(at: Date, currency: String, total: Decimal, granted: Decimal, toppedUp: Decimal) {
        self.at = at
        self.currency = currency
        self.total = total
        self.granted = granted
        self.toppedUp = toppedUp
    }

    init(at: Date, info: BalanceInfo) {
        let code = Money.normalize(info.currency)
        self.at = at
        self.currency = code.isEmpty ? info.currency.uppercased() : code
        self.total = info.total
        self.granted = info.granted
        self.toppedUp = info.toppedUp
    }
}

/// A charge inferred from two consecutive wallet readings.
struct SpendEntry: Codable, Equatable {
    /// Charges are attributed to the end of the interval they were observed in.
    let at: Date
    let currency: String
    let amount: Decimal
    /// The balance moved in a direction plain usage cannot explain.
    var uncertain: Bool = false
    /// Granted credit vanished in one step while topped-up credit was untouched,
    /// which reads as an expiry rather than as spending.
    var possibleGrantExpiry: Bool = false

    /// Whether this entry counts toward reported spend.
    var countsAsSpend: Bool { !possibleGrantExpiry }
}

/// Infers spending from the balance falling over time.
///
/// The provider publishes a balance endpoint but no usage endpoint that every
/// account can reach, so when `/v1/usage` is unavailable this is the only way to
/// answer "how much have I spent today". It is an estimate by construction: its
/// resolution is the polling interval and it cannot attribute spend to a model.
/// Anything it produces is labelled as estimated in the UI.
@MainActor
final class BalanceLedger {
    /// Entries older than this are dropped on save.
    private static let retentionDays = 400

    private struct Persisted: Codable {
        var lastSamples: [String: BalanceSample]
        var entries: [SpendEntry]
    }

    private var state = Persisted(lastSamples: [:], entries: [])
    private let url: URL

    init(filename: String = "deepseek-ledger.json") {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = support.appendingPathComponent("TokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(filename)
        load()
    }

    // MARK: - Differencing

    /// Turns two consecutive readings of the same wallet into a charge.
    ///
    /// Top-ups are added back before differencing, so money arriving mid-interval
    /// does not hide the spending that happened alongside it. Nil means "nothing
    /// worth recording" — the balance did not move.
    nonisolated static func diff(previous: BalanceSample, current: BalanceSample) -> SpendEntry? {
        guard previous.currency == current.currency else { return nil }
        guard current.at > previous.at else { return nil }

        let topUp = current.toppedUp - previous.toppedUp
        let credited = topUp > 0 ? topUp : 0
        let spend = (previous.total + credited) - current.total

        // Granted credit disappearing on its own is an expiry, not usage.
        let grantVanished = previous.granted > 0
            && current.granted == 0
            && current.toppedUp == previous.toppedUp

        if spend == 0 && !grantVanished { return nil }

        if spend < 0 {
            // The balance rose without a matching top-up: a refund or a manual
            // adjustment. Record it as zero spend but keep the marker.
            return SpendEntry(at: current.at, currency: current.currency, amount: 0, uncertain: true)
        }

        return SpendEntry(at: current.at,
                          currency: current.currency,
                          amount: spend,
                          uncertain: false,
                          possibleGrantExpiry: grantVanished)
    }

    /// Records a poll. Returns the entries it derived, for tests and logging.
    @discardableResult
    func record(_ response: BalanceResponse, at date: Date = Date()) -> [SpendEntry] {
        var derived: [SpendEntry] = []
        for info in response.balanceInfos {
            let sample = BalanceSample(at: date, info: info)
            if let previous = state.lastSamples[sample.currency],
               let entry = Self.diff(previous: previous, current: sample) {
                state.entries.append(entry)
                derived.append(entry)
            }
            state.lastSamples[sample.currency] = sample
        }
        save()
        return derived
    }

    // MARK: - Statistics

    /// Sums spend in one currency over the interval `[since, now]`. Static so the
    /// aggregation can be exercised without touching the filesystem.
    nonisolated static func total(_ entries: [SpendEntry], currency: String, since: Date, now: Date) -> Decimal {
        entries.reduce(into: Decimal.zero) { running, entry in
            guard entry.currency == currency, entry.countsAsSpend else { return }
            guard entry.at >= since, entry.at <= now else { return }
            running += entry.amount
        }
    }

    func spend(currency: String, since: Date, now: Date = Date()) -> Decimal {
        Self.total(state.entries, currency: currency, since: since, now: now)
    }

    /// Spend since local midnight.
    func spendToday(currency: String, now: Date = Date(), calendar: Calendar = .current) -> Decimal {
        spend(currency: currency, since: calendar.startOfDay(for: now), now: now)
    }

    /// Spend since the first of the local month.
    func spendThisMonth(currency: String, now: Date = Date(), calendar: Calendar = .current) -> Decimal {
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let start = calendar.date(from: components) else { return .zero }
        return spend(currency: currency, since: start, now: now)
    }

    func spendLast(days: Int, currency: String, now: Date = Date()) -> Decimal {
        spend(currency: currency, since: now.addingTimeInterval(-Double(days) * 86400), now: now)
    }

    /// Average daily spend over the trailing window, used for the runway
    /// estimate. Nil when nothing has been observed yet.
    func dailyBurn(currency: String, days: Int = 7, now: Date = Date()) -> Decimal? {
        guard let earliest = state.entries.filter({ $0.currency == currency }).map(\.at).min() else { return nil }
        let windowStart = now.addingTimeInterval(-Double(days) * 86400)
        let observedFrom = max(earliest, windowStart)
        let elapsedDays = now.timeIntervalSince(observedFrom) / 86400
        guard elapsedDays > 0.5 else { return nil }   // too little history to divide by
        let total = spend(currency: currency, since: observedFrom, now: now)
        guard total > 0 else { return nil }
        return total / Decimal(elapsedDays)
    }

    /// Whole days of runway left at the trailing burn rate.
    func daysRemaining(balance: Decimal, currency: String, now: Date = Date()) -> Int? {
        guard let burn = dailyBurn(currency: currency, now: now), burn > 0 else { return nil }
        let days = balance / burn
        return NSDecimalNumber(decimal: days).intValue
    }

    var hasHistory: Bool { !state.entries.isEmpty }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        state = decoded
    }

    /// Atomic write: a crash mid-save leaves the previous ledger intact rather
    /// than a truncated file.
    private func save() {
        prune()
        guard let data = try? JSONEncoder().encode(state) else { return }
        let temporary = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86400)
        state.entries.removeAll { $0.at < cutoff }
    }
}
