import AppKit

/// How a provider proves who the user is. The shell uses this to decide which
/// sign-in affordance the menu offers.
enum AuthKind {
    /// The provider is read through a logged-in web console (WKWebView cookies).
    case webSession(consoleURL: URL)
    /// The provider is read with a bearer token the user pastes in Settings.
    case apiKey
}

/// Whether the menu bar title should read as normal or as something the user
/// needs to look at (running out, account suspended, …).
enum Severity {
    case normal
    case warning
}

/// One consistent reading from a provider, already formatted for display.
///
/// Providers render their own numbers: a percentage-and-countdown provider and a
/// currency-balance provider have nothing useful in common at the data level,
/// and forcing them into one numeric model only adds translation layers. What
/// they share is the *shape* of a line — a metric, a caption, a notice — which
/// is what `MenuRow` carries, so the shell can draw all of them alike.
struct ProviderSnapshot {
    /// Menu bar text that follows the glyph, e.g. `42% · 2d` or `¥110.00`.
    var barText: String
    var severity: Severity
    /// Read-only detail lines for the drop-down, in display order.
    var rows: [MenuRow]
    var fetchedAt: Date

    init(barText: String, severity: Severity = .normal, rows: [MenuRow] = [], fetchedAt: Date = Date()) {
        self.barText = barText
        self.severity = severity
        self.rows = rows
        self.fetchedAt = fetchedAt
    }
}

/// A provider's latest reading in the shape the status export stores it.
///
/// Unlike `ProviderSnapshot`, which is formatted for display, this carries the
/// raw numbers so another program can read them. It deliberately has no place
/// for a credential, a cookie, a session token or an account identifier: only
/// what the export format needs.
enum ProviderStatus {
    case qwen(QwenStatus)
    case deepseek([String: DeepSeekWalletStatus])
}

/// A monitored service. Adding a new one means adding a type here and a line in
/// `ProviderRegistry` — nothing in the shell changes.
@MainActor
protocol Provider: AnyObject {
    /// Stable key used for `UserDefaults` suffixes and the Keychain account.
    var id: String { get }
    /// Single character shown at the head of the menu bar item: `Q`, `D`, …
    var glyph: String { get }
    /// Human-readable service name, used as the Settings tab title.
    var displayName: String { get }
    var authKind: AuthKind { get }
    /// False when there is no API key / no signed-in session yet.
    var isConfigured: Bool { get }

    func fetch() async throws -> ProviderSnapshot
    func signOut() async

    /// Provider-specific menu entries inserted above the shared ones.
    func extraMenuItems() -> [NSMenuItem]
    /// The provider's page in the Settings window.
    func settingsPane() -> NSView

    /// The last successful reading, for the status export. Kept separate from
    /// `fetch()`'s return value because the export needs the raw numbers that
    /// `ProviderSnapshot` has already formatted away. Nil when there is nothing
    /// to export yet.
    var statusValue: ProviderStatus? { get }
}

extension Provider {
    func extraMenuItems() -> [NSMenuItem] { [] }

    /// Providers that contribute nothing to the status file inherit nil.
    var statusValue: ProviderStatus? { nil }

    /// Per-provider "Show in menu bar" toggle, defaulting to on.
    var isVisible: Bool {
        get {
            let key = Self.visibilityKey(id)
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.visibilityKey(id))
        }
    }

    static func visibilityKey(_ id: String) -> String { "provider.\(id).visible" }
}

/// Errors every provider shares. Provider-specific failures use their own types
/// and surface through `.failed(message)`.
enum ProviderError: LocalizedError {
    /// The provider cannot read anything until the user signs in or pastes a key.
    /// The shell turns this into `.needsAuth` rather than an error row.
    case needsAuth

    var errorDescription: String? {
        switch self {
        case .needsAuth: return "Not signed in"
        }
    }
}
