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

/// The app's single menu bar item. It shows one provider at a time and rotates
/// through them; the drop-down always shows every provider at once.
///
/// A status item per provider would eat menu bar width that other apps need.
/// Showing every provider side by side in one title costs almost as much width,
/// and it grows with each provider added. Rotating keeps the footprint fixed at
/// one reading no matter how many accounts are configured, and the full picture
/// is one click away.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// How long each provider holds the menu bar before the next one takes over.
    static let rotationInterval: TimeInterval = 60

    private let statusItem: NSStatusItem
    private var sessions: [ProviderSession]

    /// Which session the title is currently showing.
    private var rotationIndex = 0
    private var rotationTimer: Timer?

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
        startRotation()
    }

    /// Swaps in a new set of visible providers, e.g. after a Settings change.
    func setSessions(_ sessions: [ProviderSession]) {
        self.sessions = sessions
        // The provider that was on screen may be gone, or may have moved.
        rotationIndex = min(rotationIndex, max(sessions.count - 1, 0))
        render()
        startRotation()
    }

    func tearDown() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Rotation

    /// Advances the carousel, wrapping around. Returns 0 for an empty list so
    /// the index is always safe to subscript against a non-empty one.
    nonisolated static func nextIndex(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current + 1) % count
    }

    /// One timer, only while there is more than one provider to show. A single
    /// provider has nothing to rotate to, so it holds the title indefinitely.
    private func startRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard sessions.count > 1 else { return }

        let timer = Timer(timeInterval: Self.rotationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        // The carousel is ambient: let the system coalesce it with other timers.
        timer.tolerance = Self.rotationInterval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    private func advance() {
        rotationIndex = Self.nextIndex(current: rotationIndex, count: sessions.count)
        render()
    }

    // MARK: - Title

    func render() {
        guard let button = statusItem.button else { return }
        guard sessions.indices.contains(rotationIndex) else {
            button.attributedTitle = attributed("TokenBar", color: .labelColor)
            return
        }
        let segment = sessions[rotationIndex].segment
        button.attributedTitle = attributed(segment.rendered, color: color(for: segment.severity))
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

    /// The title must not change out from under someone reading the menu, so the
    /// carousel holds still while it is open and resumes from a full interval
    /// afterwards.
    func menuWillOpen(_ menu: NSMenu) {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        startRotation()
    }

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
