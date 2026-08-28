import Foundation

/// `TokenBar --self-check` runs the decode, arithmetic and formatting
/// assertions without needing a full Xcode install (Command Line Tools ship no
/// XCTest). CI runs it on every push.
enum SelfCheck {
    // MARK: - Fixtures

    /// Verbatim response captured from a live logged-in Qwen console session, so
    /// the checks pin the real contract rather than a guess.
    private static let qwenPayload = """
    {"loggedIn":true,
     "usage":{"per1WeekResetTime":1788262920000,"per1WeekPercentage":1},
     "subscription":{"instanceCode":"sfm_tokenplansolo_public_intl-sg-x",
                     "specCode":"standard","remainingDays":337,
                     "startTime":1785547613000,"endTime":1817136000000,
                     "autoRenewFlag":false,"status":"VALID"}}
    """

    /// The example response printed in the published balance API reference.
    private static let balancePayload = """
    {"is_available":true,
     "balance_infos":[{"currency":"CNY","total_balance":"110.00",
                       "granted_balance":"10.00","topped_up_balance":"100.00"}]}
    """

    private static var failures: [String] = []

    static func run() -> Never {
        failures = []

        checkQwenPayload()
        checkBalancePayload()
        checkMoney()
        checkPeakSchedule()
        checkLedger()
        checkPricing()
        checkMenuBarTitle()
        checkFormatters()

        print("")
        if failures.isEmpty {
            print("self-check passed")
            exit(0)
        }
        print("self-check failed: \(failures.joined(separator: ", "))")
        exit(1)
    }

    private static func expect(_ label: String, _ actual: String, _ expected: String) {
        if actual == expected {
            print("  ok   \(label): \(actual)")
        } else {
            print("  FAIL \(label): got \(actual), expected \(expected)")
            failures.append(label)
        }
    }

    // MARK: - Qwen

    private static func checkQwenPayload() {
        print("Qwen payload")
        func decode(_ json: String) -> BridgeResult? {
            try? JSONDecoder().decode(BridgeResult.self, from: Data(json.utf8))
        }
        guard let live = decode(qwenPayload) else {
            print("  FAIL live payload did not decode")
            failures.append("qwen payload decode")
            return
        }
        expect("loggedIn", "\(live.loggedIn)", "true")
        expect("specCode", live.subscription?.specCode ?? "nil", "standard")

        let snapshot = PlanSnapshot(bridge: live)
        // per1WeekPercentage is the *used* share: 1 must render as 0% left,
        // which is what the console page showed when this payload was captured.
        expect("remaining %", "\(snapshot.remainingPercent ?? -1)", "0.0")
        expect("remainingDays", "\(snapshot.remainingDays ?? -1)", "337")
        expect("status", snapshot.status ?? "nil", "VALID")
        expect("autoRenew", "\(snapshot.autoRenew ?? true)", "false")

        let resetFormatter = DateFormatter()
        resetFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        resetFormatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        let resetText = snapshot.resetTime.map { resetFormatter.string(from: $0) } ?? "nil"
        expect("reset time (UTC+8)", resetText, "2026-09-01 19:42:00")

        let half = decode(#"{"loggedIn":true,"usage":{"per1WeekResetTime":1,"per1WeekPercentage":0.5}}"#)
            .map { PlanSnapshot(bridge: $0) }
        expect("half used -> half left", "\(half?.remainingPercent ?? -1)", "50.0")
        expect("logged out", "\(decode(#"{"loggedIn":false}"#)?.loggedIn ?? true)", "false")
        expect("bridge error", decode(#"{"loggedIn":true,"error":"gateway error"}"#)?.error ?? "nil", "gateway error")
    }

    // MARK: - Balance

    private static func checkBalancePayload() {
        print("Balance payload")
        guard let balance = try? JSONDecoder().decode(BalanceResponse.self, from: Data(balancePayload.utf8)) else {
            print("  FAIL balance payload did not decode")
            failures.append("balance decode")
            return
        }
        expect("is_available", "\(balance.isAvailable)", "true")
        expect("wallet count", "\(balance.balanceInfos.count)", "1")
        expect("total as Decimal", "\(balance.balanceInfos[0].total)", "110")
        expect("granted as Decimal", "\(balance.balanceInfos[0].granted)", "10")
        expect("display", balance.display(preferring: nil), "¥110.00")
        expect("display, currency present", balance.display(preferring: "CNY"), "¥110.00")
        // Asking for a currency the wallet does not hold must never convert; it
        // shows the real wallet, prefixed with what that wallet actually is.
        expect("display, currency absent", balance.display(preferring: "USD"), "CNY ¥110.00")
        expect("primary currency", balance.primaryCurrency ?? "nil", "CNY")
        expect("multi-currency", "\(balance.isMultiCurrency)", "false")

        let dual = """
        {"is_available":false,"balance_infos":[
          {"currency":"USD","total_balance":"1.50","granted_balance":"0.00","topped_up_balance":"1.50"},
          {"currency":"CNY","total_balance":"70.16","granted_balance":"0.00","topped_up_balance":"70.16"}]}
        """
        guard let two = try? JSONDecoder().decode(BalanceResponse.self, from: Data(dual.utf8)) else {
            print("  FAIL dual-currency payload did not decode")
            failures.append("dual balance decode")
            return
        }
        expect("two currencies", two.currencies.joined(separator: ","), "CNY,USD")
        expect("no primary when mixed", two.primaryCurrency ?? "nil", "nil")
        expect("prefers requested wallet", two.display(preferring: "USD"), "$1.50")
        // With no preference the CNY-first fallback applies.
        expect("CNY-first fallback", two.display(preferring: nil), "¥70.16")

        let unknown = """
        {"is_available":true,"balance_infos":[
          {"currency":"XYZ","total_balance":"5","granted_balance":"0","topped_up_balance":"5"}]}
        """
        let odd = try? JSONDecoder().decode(BalanceResponse.self, from: Data(unknown.utf8))
        expect("unknown currency", odd?.display(preferring: nil) ?? "nil", "XYZ 5.00")
    }

    private static func checkMoney() {
        print("Money")
        expect("parse plain", "\(Money.parse("110.00"))", "110")
        expect("parse padded", "\(Money.parse("  7.05 "))", "7.05")
        expect("parse junk", "\(Money.parse("n/a"))", "0")
        expect("normalize rmb", Money.normalize("rmb"), "CNY")
        expect("normalize dollar", Money.normalize("US$"), "USD")
        expect("normalize unknown", Money.normalize("gbp"), "")
        expect("symbol cny", Money.symbol("CNY"), "¥")
        expect("symbol unknown", Money.symbol("gbp"), "GBP ")
        // Truncating, not rounding: never claim more money than the wallet holds.
        expect("amount truncates", Money.amount(Decimal(string: "1.999")!), "1.99")
        expect("format", Money.format(Decimal(string: "0.5")!, currency: "USD"), "$0.50")
    }

    // MARK: - Peak schedule

    private static func checkPeakSchedule() {
        print("Peak schedule")
        func utc(_ text: String) -> Date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.date(from: text)!
        }
        func band(_ text: String) -> String {
            PeakSchedule.band(at: utc(text)) == .peak ? "peak" : "off"
        }

        // 2026-08-26 is a Wednesday; 2026-08-29 a Saturday, 2026-08-30 a Sunday.
        expect("Wed 00:59 before window", band("2026-08-26 00:59:59"), "off")
        expect("Wed 01:00 window opens", band("2026-08-26 01:00:00"), "peak")
        expect("Wed 03:59 still peak", band("2026-08-26 03:59:59"), "peak")
        expect("Wed 04:00 window closes", band("2026-08-26 04:00:00"), "off")
        expect("Wed 05:30 gap", band("2026-08-26 05:30:00"), "off")
        expect("Wed 06:00 second window", band("2026-08-26 06:00:00"), "peak")
        expect("Wed 09:59 still peak", band("2026-08-26 09:59:59"), "peak")
        expect("Wed 10:00 closes", band("2026-08-26 10:00:00"), "off")
        expect("Wed 23:00 night", band("2026-08-26 23:00:00"), "off")
        expect("Sat 02:00 weekend", band("2026-08-29 02:00:00"), "off")
        expect("Sun 07:00 weekend", band("2026-08-30 07:00:00"), "off")
        expect("Mon 02:00 weekday", band("2026-08-31 02:00:00"), "peak")

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let fromOffPeak = PeakSchedule.nextTransition(after: utc("2026-08-26 00:10:00"))
        expect("next transition into peak", fromOffPeak.map { f.string(from: $0) } ?? "nil", "2026-08-26 01:00")
        let fromPeak = PeakSchedule.nextTransition(after: utc("2026-08-26 01:10:00"))
        expect("next transition out of peak", fromPeak.map { f.string(from: $0) } ?? "nil", "2026-08-26 04:00")
        // Friday's last window closes at 10:00 and nothing reopens until Monday.
        let fridayEvening = PeakSchedule.nextTransition(after: utc("2026-08-28 11:00:00"))
        expect("weekend skip", fridayEvening.map { f.string(from: $0) } ?? "nil", "2026-08-31 01:00")
    }

    // MARK: - Ledger

    private static func checkLedger() {
        print("Balance ledger")
        func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_788_000_000 + seconds) }
        func sample(_ seconds: Double, total: String, granted: String = "0", toppedUp: String = "0", currency: String = "CNY") -> BalanceSample {
            BalanceSample(at: at(seconds),
                          currency: currency,
                          total: Money.parse(total),
                          granted: Money.parse(granted),
                          toppedUp: Money.parse(toppedUp))
        }
        func amount(_ entry: SpendEntry?) -> String {
            entry.map { "\($0.amount)" } ?? "nil"
        }

        let plain = BalanceLedger.diff(previous: sample(0, total: "100.00", toppedUp: "100.00"),
                                       current: sample(300, total: "97.50", toppedUp: "100.00"))
        expect("plain spend", amount(plain), "2.5")
        expect("plain counts", "\(plain?.countsAsSpend ?? false)", "true")

        expect("no movement", amount(BalanceLedger.diff(previous: sample(0, total: "100.00"),
                                                        current: sample(300, total: "100.00"))), "nil")

        // A top-up mid-interval must not mask the spending around it:
        // 100 -> +50 topped up -> ends at 145, so 5 was spent.
        let toppedUp = BalanceLedger.diff(previous: sample(0, total: "100.00", toppedUp: "100.00"),
                                          current: sample(300, total: "145.00", toppedUp: "150.00"))
        expect("spend across a top-up", amount(toppedUp), "5")

        // Balance rose with no top-up: a refund or adjustment, not usage.
        let refunded = BalanceLedger.diff(previous: sample(0, total: "100.00", toppedUp: "100.00"),
                                          current: sample(300, total: "120.00", toppedUp: "100.00"))
        expect("unexplained rise is zero", amount(refunded), "0")
        expect("unexplained rise flagged", "\(refunded?.uncertain ?? false)", "true")

        // Granted credit vanishing on its own is an expiry, not spending.
        let expired = BalanceLedger.diff(previous: sample(0, total: "110.00", granted: "10.00", toppedUp: "100.00"),
                                         current: sample(300, total: "100.00", granted: "0", toppedUp: "100.00"))
        expect("grant expiry flagged", "\(expired?.possibleGrantExpiry ?? false)", "true")
        expect("grant expiry excluded", "\(expired?.countsAsSpend ?? true)", "false")

        expect("currency mismatch ignored",
               amount(BalanceLedger.diff(previous: sample(0, total: "100.00"),
                                         current: sample(300, total: "90.00", currency: "USD"))), "nil")
        expect("out-of-order ignored",
               amount(BalanceLedger.diff(previous: sample(300, total: "100.00"),
                                         current: sample(0, total: "90.00"))), "nil")

        // Decimal keeps the cent that a binary float would lose.
        let cents = BalanceLedger.diff(previous: sample(0, total: "0.30", toppedUp: "0.30"),
                                       current: sample(300, total: "0.10", toppedUp: "0.30"))
        expect("no float drift", amount(cents), "0.2")

        let entries = [
            SpendEntry(at: at(0), currency: "CNY", amount: Money.parse("1.00")),
            SpendEntry(at: at(100), currency: "CNY", amount: Money.parse("2.00")),
            SpendEntry(at: at(200), currency: "USD", amount: Money.parse("9.00")),
            SpendEntry(at: at(300), currency: "CNY", amount: Money.parse("4.00"), possibleGrantExpiry: true)
        ]
        expect("sum one currency",
               "\(BalanceLedger.total(entries, currency: "CNY", since: at(-1), now: at(400)))", "3")
        expect("sum excludes other currency",
               "\(BalanceLedger.total(entries, currency: "USD", since: at(-1), now: at(400)))", "9")
        expect("sum respects window",
               "\(BalanceLedger.total(entries, currency: "CNY", since: at(50), now: at(400)))", "2")
    }

    // MARK: - Pricing

    private static func checkPricing() {
        print("Pricing")
        expect("flash output peak",
               "\(Pricing.rate(model: "deepseek-v4-flash", kind: .output, band: .peak) ?? -1)", "1.32")
        // Off-peak is exactly half the peak rate.
        expect("flash output off-peak",
               "\(Pricing.rate(model: "deepseek-v4-flash", kind: .output, band: .offPeak) ?? -1)", "0.66")
        expect("pro cache miss peak",
               "\(Pricing.rate(model: "deepseek-v4-pro", kind: .cacheMiss, band: .peak) ?? -1)", "1.32")
        expect("vision matches flash",
               "\(Pricing.rate(model: "deepseek-v4-flash-vision-exp", kind: .cacheHit, band: .peak) ?? -1)", "0.014")
        // An unknown model yields no estimate rather than a wrong one.
        expect("unknown model", Pricing.rate(model: "gpt-9", kind: .output, band: .peak).map { "\($0)" } ?? "nil", "nil")
    }

    // MARK: - Menu bar title

    private static func checkMenuBarTitle() {
        print("Menu bar title")
        expect("segment rendering",
               MenuBarSegment(glyph: "Q", text: "42% · 2d", severity: .normal).rendered,
               "Q 42% · 2d")
        expect("balance segment",
               MenuBarSegment(glyph: "D", text: "¥110.00", severity: .normal).rendered,
               "D ¥110.00")
        expect("placeholder segment",
               MenuBarSegment(glyph: "D", text: "⚠", severity: .stale).rendered,
               "D ⚠")

        print("Menu bar rotation")
        // Two providers alternate; the index must wrap, never run off the end.
        expect("0 -> 1 of 2", "\(MenuBarController.nextIndex(current: 0, count: 2))", "1")
        expect("1 wraps to 0", "\(MenuBarController.nextIndex(current: 1, count: 2))", "0")
        expect("2 wraps to 0 of 3", "\(MenuBarController.nextIndex(current: 2, count: 3))", "0")
        // A single provider holds the title: advancing must stay put.
        expect("single provider stays", "\(MenuBarController.nextIndex(current: 0, count: 1))", "0")
        // A stale index from a provider that was just hidden must not crash.
        expect("stale index of 2", "\(MenuBarController.nextIndex(current: 5, count: 2))", "0")
        expect("empty list", "\(MenuBarController.nextIndex(current: 3, count: 0))", "0")
        expect("interval is one minute", "\(Int(MenuBarController.rotationInterval))", "60")
    }

    // MARK: - Formatters

    private static func checkFormatters() {
        print("Formatters")
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        expect("3 days", Formatters.countdown(to: now.addingTimeInterval(3 * 86400), from: now), "3d")
        expect("5 hours", Formatters.countdown(to: now.addingTimeInterval(5 * 3600), from: now), "5h")
        expect("38 minutes", Formatters.countdown(to: now.addingTimeInterval(38 * 60), from: now), "38m")
        expect("10 seconds", Formatters.countdown(to: now.addingTimeInterval(10), from: now), "1m")
        expect("past due", Formatters.countdown(to: now.addingTimeInterval(-60), from: now), "now")
        expect("percent 0", Formatters.percent(0), "0%")
        expect("percent 42", Formatters.percent(42), "42%")
        expect("percent 42.35", Formatters.percent(42.35), "42.4%")
        expect("api date is UTC", Formatters.apiDate.string(from: now), "2026-08-29")
    }
}
