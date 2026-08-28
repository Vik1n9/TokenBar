import AppKit

/// How one provider's segment should be tinted in the shared title.
enum SegmentTint {
    case normal
    case warning
    /// Last known numbers, kept on screen after a failed refresh.
    case stale
}

/// One provider's contribution to the menu bar title.
struct MenuBarSegment: Equatable {
    let glyph: String
    let text: String
    let severity: SegmentTint

    /// `Q 42% · 2d`
    var rendered: String { "\(glyph) \(text)" }
}

/// The app's single menu bar item. Every provider shares it: one glyph-prefixed
/// segment each in the title, one section each in the drop-down.
///
/// A status item per provider would eat menu bar width that other apps need, and
/// would scatter one app's readings across several unrelated buttons.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Two spaces between segments: wide enough to group each glyph with its own
    /// number, without adding a separator glyph that competes with the `·` some
    /// providers already use inside their own text.
    static let segmentGap = "  "

    private let statusItem: NSStatusItem
    private var sessions: [ProviderSession]

    private let refreshAll: () -> Void
    private let openSettings: () -> Void
    private let signIn: (Provider) -> Void

    init(sessions: [ProviderSession],
         refreshAll: @escaping () -> Void,
         openSettings: @escaping () -> Void,
         signIn: @escaping (Provider) -> Void) {
        self.sessions = sessions
        self.refreshAll = refreshAll
        self.openSettings = openSettings
        self.signIn = signIn
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render()
    }

    /// Swaps in a new set of visible providers, e.g. after a Settings change.
    func setSessions(_ sessions: [ProviderSession]) {
        self.sessions = sessions
        render()
    }

    func tearDown() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Title

    /// Plain text of the whole title. Separate from the attributed build so the
    /// composition rule can be checked without AppKit.
    nonisolated static func compose(_ segments: [MenuBarSegment]) -> String {
        segments.map(\.rendered).joined(separator: segmentGap)
    }

    func render() {
        guard let button = statusItem.button else { return }
        let segments = sessions.map(\.segment)
        guard !segments.isEmpty else {
            button.attributedTitle = attributed("TokenBar", color: .labelColor)
            return
        }

        let title = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                title.append(attributed(Self.segmentGap, color: .labelColor))
            }
            title.append(attributed(segment.rendered, color: color(for: segment.severity)))
        }
        button.attributedTitle = title
    }

    private func color(for severity: SegmentTint) -> NSColor {
        switch severity {
        case .normal: return .labelColor
        case .warning: return .systemRed
        case .stale: return .secondaryLabelColor
        }
    }

    private func attributed(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: color
        ])
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for (index, session) in sessions.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            buildSection(for: session, into: menu)
        }

        menu.addItem(.separator())
        menu.addItem(action("Refresh Now", #selector(refreshTapped)))
        menu.addItem(action("Settings…", #selector(settingsTapped)))
        menu.addItem(action("Quit TokenBar", #selector(quitTapped), key: "q"))

        refreshAll()
    }

    private func buildSection(for session: ProviderSession, into menu: NSMenu) {
        let provider = session.provider
        menu.addItem(header("\(provider.glyph)  \(provider.displayName)"))

        switch session.store.state {
        case .unknown:
            menu.addItem(info("Loading…"))
        case .needsAuth:
            switch provider.authKind {
            case .webSession: menu.addItem(info("Not signed in"))
            case .apiKey: menu.addItem(info("No API key — add one in Settings"))
            }
        case .failed(let message):
            menu.addItem(info("Last refresh failed: \(message)"))
            if let snapshot = session.store.snapshot {
                snapshot.rows.forEach { menu.addItem(info($0)) }
                menu.addItem(info("Updated \(Formatters.clock.string(from: snapshot.fetchedAt))"))
            }
        case .ok:
            if let snapshot = session.store.snapshot {
                snapshot.rows.forEach { menu.addItem(info($0)) }
                menu.addItem(info("Updated \(Formatters.clock.string(from: snapshot.fetchedAt))"))
            }
        }

        // Per-provider actions sit inside the provider's own section, indented
        // so they read as belonging to it rather than to the app as a whole.
        for item in provider.extraMenuItems() {
            item.indentationLevel = 1
            menu.addItem(item)
        }
        if case .webSession = provider.authKind {
            let item: NSMenuItem
            if session.store.state == .needsAuth {
                item = action("Sign In…", #selector(signInTapped))
            } else {
                item = action("Sign Out", #selector(signOutTapped))
            }
            item.representedObject = session
            item.indentationLevel = 1
            menu.addItem(item)
        }
    }

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        ])
        return item
    }

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func refreshTapped() { refreshAll() }
    @objc private func settingsTapped() { openSettings() }
    @objc private func quitTapped() { NSApp.terminate(nil) }

    @objc private func signInTapped(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? ProviderSession else { return }
        signIn(session.provider)
    }

    @objc private func signOutTapped(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? ProviderSession else { return }
        session.signOut()
    }
}
