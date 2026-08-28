import AppKit

/// Owns one provider end to end: its status item, its drop-down, its store, and
/// the in-flight refresh task. Providers never touch AppKit state directly.
@MainActor
final class ProviderController: NSObject, NSMenuDelegate {
    let provider: Provider

    private let store = ProviderStore()
    private let statusItem: NSStatusItem
    private let openSettings: () -> Void
    private let signIn: (Provider) -> Void

    private var refreshTask: Task<Void, Never>?

    init(provider: Provider,
         openSettings: @escaping () -> Void,
         signIn: @escaping (Provider) -> Void) {
        self.provider = provider
        self.openSettings = openSettings
        self.signIn = signIn
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        store.onChange = { [weak self] in self?.render() }
        render()
    }

    /// Removes the status item. Called when the user hides this provider.
    func tearDown() {
        refreshTask?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Refresh

    /// Coalesces refreshes: a new request replaces one still in flight.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            guard provider.isConfigured else {
                store.markNeedsAuth()
                return
            }
            do {
                let snapshot = try await provider.fetch()
                if Task.isCancelled { return }
                store.apply(snapshot)
            } catch is CancellationError {
                return
            } catch ProviderError.needsAuth {
                if Task.isCancelled { return }
                store.markNeedsAuth()
            } catch {
                if Task.isCancelled { return }
                store.fail(error.localizedDescription)
            }
        }
    }

    func signOutAndRefresh() {
        refreshTask?.cancel()
        Task { @MainActor in
            await provider.signOut()
            store.markNeedsAuth()
        }
    }

    // MARK: - Title

    private func render() {
        guard let button = statusItem.button else { return }
        let glyph = provider.glyph
        switch store.state {
        case .unknown:
            button.attributedTitle = title("\(glyph) …", color: .labelColor)
        case .needsAuth:
            button.attributedTitle = title("\(glyph) —", color: .labelColor)
        case .failed:
            // Keep the last good numbers visible; the warning sign says they are stale.
            if let snapshot = store.snapshot {
                button.attributedTitle = title("\(glyph) \(snapshot.barText) ⚠", color: .secondaryLabelColor)
            } else {
                button.attributedTitle = title("\(glyph) ⚠", color: .labelColor)
            }
        case .ok:
            guard let snapshot = store.snapshot else {
                button.attributedTitle = title("\(glyph) —", color: .labelColor)
                return
            }
            let color: NSColor = snapshot.severity == .warning ? .systemRed : .labelColor
            button.attributedTitle = title("\(glyph) \(snapshot.barText)", color: color)
        }
    }

    private func title(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: color
        ])
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildDetails(into: menu)
        menu.addItem(.separator())

        menu.addItem(action("Refresh Now", #selector(refreshTapped)))
        provider.extraMenuItems().forEach { menu.addItem($0) }

        if case .webSession = provider.authKind {
            switch store.state {
            case .needsAuth:
                menu.addItem(action("Sign In…", #selector(signInTapped)))
            default:
                menu.addItem(action("Sign Out", #selector(signOutTapped)))
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(settingsTapped)))
        menu.addItem(action("Quit TokenBar", #selector(quitTapped), key: "q"))

        refresh()
    }

    private func buildDetails(into menu: NSMenu) {
        menu.addItem(header(provider.displayName))

        switch store.state {
        case .unknown:
            menu.addItem(info("Loading…"))
            return
        case .needsAuth:
            switch provider.authKind {
            case .webSession:
                menu.addItem(info("Not signed in"))
            case .apiKey:
                menu.addItem(info("No API key — add one in Settings"))
            }
            return
        case .failed(let message):
            menu.addItem(info("Last refresh failed: \(message)"))
            if store.snapshot != nil { menu.addItem(.separator()) }
        case .ok:
            break
        }

        guard let snapshot = store.snapshot else { return }
        snapshot.rows.forEach { menu.addItem(info($0)) }
        menu.addItem(info("Updated \(Formatters.clock.string(from: snapshot.fetchedAt))"))
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
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func refreshTapped() { refresh() }
    @objc private func signInTapped() { signIn(provider) }
    @objc private func signOutTapped() { signOutAndRefresh() }
    @objc private func settingsTapped() { openSettings() }
    @objc private func quitTapped() { NSApp.terminate(nil) }
}
