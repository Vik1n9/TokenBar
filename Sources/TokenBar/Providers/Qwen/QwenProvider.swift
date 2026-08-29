import AppKit

/// QwenCloud Token Plan, read through a logged-in console session.
///
/// The session, bridge and login window are unchanged from the standalone
/// QwenTokenBar app; this type only adapts them to the shared `Provider` shape.
@MainActor
final class QwenProvider: Provider {
    let id = "qwen"
    let glyph = "Q"
    let displayName = "QwenCloud Token Plan"
    var authKind: AuthKind { .webSession(consoleURL: QwenSession.consoleURL) }

    /// A web session cannot be probed without loading the page, so this is
    /// always true and `fetch()` reports `.needsAuth` when the bridge says so.
    var isConfigured: Bool { true }

    private let session = QwenSession()

    /// Set by the shell: opens the login window. The provider does not own any
    /// window itself, so Settings and the menu can both trigger the same flow.
    var onSignInRequested: (() -> Void)?
    /// Set by the shell: asks for an immediate refresh after a state change.
    var onRefreshRequested: (() -> Void)?

    func fetch() async throws -> ProviderSnapshot {
        let result = try await session.fetchSnapshot()
        guard result.loggedIn else { throw ProviderError.needsAuth }
        if let error = result.error { throw SessionError.bridgeFailed(error) }

        let plan = PlanSnapshot(bridge: result)
        return ProviderSnapshot(barText: barText(plan),
                                severity: (plan.remainingPercent ?? 100) < 10 ? .warning : .normal,
                                rows: Self.rows(plan, now: plan.fetchedAt),
                                fetchedAt: plan.fetchedAt)
    }

    func signOut() async {
        await session.logOut()
    }

    /// Called after the login window reports success, so the next refresh does
    /// not reuse the page that was still logged out.
    func invalidateSession() {
        session.invalidate()
    }

    func extraMenuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Open Console", action: #selector(openConsole), keyEquivalent: "")
        item.target = self
        return [item]
    }

    @objc private func openConsole() {
        NSWorkspace.shared.open(QwenSession.consoleURL)
    }

    func settingsPane() -> NSView {
        QwenSettingsPane(provider: self)
    }

    // MARK: - Display

    private func barText(_ plan: PlanSnapshot) -> String {
        var text = plan.remainingPercent.map { Formatters.percent($0) } ?? "?"
        if let reset = plan.resetTime {
            text += " · " + Formatters.countdown(to: reset)
        }
        return text
    }

    /// The drop-down answers two questions: how much is left, and when it comes
    /// back. Plan tier, expiry and auto-renew are static account trivia that
    /// only made the menu harder to scan, so they are no longer shown.
    nonisolated static func rows(_ plan: PlanSnapshot, now: Date = Date()) -> [MenuRow] {
        var rows: [MenuRow] = []
        if let remaining = plan.remainingPercent {
            rows.append(.metric("7-day allowance",
                                Formatters.percent(remaining) + " left",
                                fraction: remaining / 100,
                                isWarning: remaining < 10))
        } else {
            rows.append(.metric("7-day allowance", "unknown"))
        }
        if let reset = plan.resetTime {
            rows.append(.caption("Resets in \(Formatters.countdown(to: reset, from: now))"))
        }
        return rows
    }
}
