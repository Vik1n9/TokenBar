import AppKit

/// Preferences: one General tab plus one tab per provider, each supplied by the
/// provider itself so the shell never learns a provider's specifics.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var intervalPopUp: NSPopUpButton?
    private var launchCheckbox: NSButton?
    private var updateCheckbox: NSButton?
    private var updateStatusLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var visibilityChecks: [NSButton] = []

    private let refreshService: RefreshService
    private let updateChecker: UpdateChecker
    private let providers: [Provider]
    private let onVisibilityChanged: () -> Void

    init(refreshService: RefreshService,
         updateChecker: UpdateChecker,
         providers: [Provider],
         onVisibilityChanged: @escaping () -> Void) {
        self.refreshService = refreshService
        self.updateChecker = updateChecker
        self.providers = providers
        self.onVisibilityChanged = onVisibilityChanged
    }

    /// Called by the shell when a check finishes, so an open window shows the
    /// outcome without the user reopening it.
    func updateStatusChanged() {
        guard window != nil else { return }
        syncUpdateStatus()
    }

    func show() {
        if let window {
            syncControls()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))
        tabs.addTabViewItem(generalTab())
        for provider in providers {
            let item = NSTabViewItem(identifier: provider.id)
            item.label = provider.displayName
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 396, height: 300))
            let pane = provider.settingsPane()
            pane.frame = NSRect(x: 16, y: 84, width: 380, height: 200)
            // Panes are laid out from a fixed size; pin them to the top so the
            // taller General tab does not leave a gap above them.
            pane.autoresizingMask = [.width, .minYMargin]
            container.autoresizingMask = [.width, .height]
            container.addSubview(pane)
            item.view = container
            tabs.addTabViewItem(item)
        }

        let win = NSWindow(contentRect: tabs.frame,
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.isReleasedWhenClosed = false   // we hold the reference ourselves
        win.title = "TokenBar Settings"
        win.contentView = tabs
        win.center()
        win.delegate = self

        window = win
        syncControls()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func generalTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "general")
        item.label = "General"

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 396, height: 300))

        let intervalLabel = makeLabel("Refresh every", frame: NSRect(x: 24, y: 256, width: 110, height: 20))
        let popUp = NSPopUpButton(frame: NSRect(x: 140, y: 251, width: 120, height: 26), pullsDown: false)
        popUp.addItems(withTitles: RefreshService.availableIntervals.map { "\($0) min" })
        popUp.target = self
        popUp.action = #selector(intervalChanged(_:))

        let checkbox = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(launchToggled(_:)))
        checkbox.frame = NSRect(x: 22, y: 220, width: 200, height: 22)

        let showLabel = makeLabel("Show in menu bar", frame: NSRect(x: 24, y: 190, width: 160, height: 20))
        showLabel.textColor = .secondaryLabelColor

        var y: CGFloat = 166
        visibilityChecks = providers.map { provider in
            let box = NSButton(checkboxWithTitle: "\(provider.glyph)  \(provider.displayName)",
                               target: self,
                               action: #selector(visibilityToggled(_:)))
            box.frame = NSRect(x: 22, y: y, width: 340, height: 22)
            box.identifier = NSUserInterfaceItemIdentifier(provider.id)
            y -= 26
            return box
        }

        // Updates: the app only ever tells the user a release exists. Nothing
        // is downloaded or installed without them asking for it.
        let updatesLabel = makeLabel("Updates", frame: NSRect(x: 24, y: 118, width: 160, height: 20))
        updatesLabel.textColor = .secondaryLabelColor

        let updates = NSButton(checkboxWithTitle: "Check for new versions automatically",
                               target: self,
                               action: #selector(updateCheckToggled(_:)))
        updates.frame = NSRect(x: 22, y: 94, width: 300, height: 22)

        let checkNow = NSButton(title: "Check Now", target: self, action: #selector(checkForUpdatesTapped))
        checkNow.bezelStyle = .rounded
        checkNow.frame = NSRect(x: 22, y: 62, width: 110, height: 26)

        let updateStatus = makeLabel("", frame: NSRect(x: 140, y: 66, width: 232, height: 20))
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.lineBreakMode = .byTruncatingTail

        let status = makeLabel("", frame: NSRect(x: 24, y: 40, width: 348, height: 20))
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)

        // Unofficial-tool notice, so the disclaimer is visible in the app itself
        // and not only in the README.
        let disclaimer = NSTextField(wrappingLabelWithString:
            "Unofficial tool. Not affiliated with, endorsed by, or sponsored by any of the services it reads from. All product names and trademarks are the property of their respective owners.")
        disclaimer.frame = NSRect(x: 24, y: 0, width: 348, height: 44)
        disclaimer.textColor = .tertiaryLabelColor
        disclaimer.font = .systemFont(ofSize: 10)
        disclaimer.isSelectable = false

        ([intervalLabel, popUp, checkbox, showLabel, updatesLabel, updates, checkNow,
          updateStatus, status, disclaimer] as [NSView] + visibilityChecks)
            .forEach { content.addSubview($0) }

        intervalPopUp = popUp
        launchCheckbox = checkbox
        updateCheckbox = updates
        updateStatusLabel = updateStatus
        statusLabel = status

        item.view = content
        return item
    }

    private func makeLabel(_ text: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        return field
    }

    private func syncControls() {
        if let index = RefreshService.availableIntervals.firstIndex(of: refreshService.intervalMinutes) {
            intervalPopUp?.selectItem(at: index)
        }
        launchCheckbox?.state = LoginItemManager.isEnabled ? .on : .off
        updateCheckbox?.state = updateChecker.isEnabled ? .on : .off
        syncUpdateStatus()
        for box in visibilityChecks {
            guard let id = box.identifier?.rawValue,
                  let provider = providers.first(where: { $0.id == id }) else { continue }
            box.state = provider.isVisible ? .on : .off
        }
    }

    private func syncUpdateStatus() {
        let text = updateChecker.status.isEmpty
            ? "TokenBar \(UpdateChecker.currentVersion)"
            : updateChecker.status
        updateStatusLabel?.stringValue = text
    }

    // MARK: - Actions

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard RefreshService.availableIntervals.indices.contains(index) else { return }
        refreshService.intervalMinutes = RefreshService.availableIntervals[index]
    }

    @objc private func launchToggled(_ sender: NSButton) {
        if let message = LoginItemManager.setEnabled(sender.state == .on) {
            statusLabel?.stringValue = message
            sender.state = LoginItemManager.isEnabled ? .on : .off
        } else {
            statusLabel?.stringValue = ""
        }
    }

    @objc private func updateCheckToggled(_ sender: NSButton) {
        updateChecker.isEnabled = sender.state == .on
        syncUpdateStatus()
    }

    @objc private func checkForUpdatesTapped() {
        updateChecker.check(userInitiated: true)
        syncUpdateStatus()
    }

    @objc private func visibilityToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let provider = providers.first(where: { $0.id == id }) else { return }
        // Keep at least one item on screen; with none, the app has no UI left.
        if sender.state == .off, providers.filter({ $0.isVisible }).count <= 1 {
            sender.state = .on
            statusLabel?.stringValue = "At least one provider has to stay visible."
            return
        }
        provider.isVisible = sender.state == .on
        statusLabel?.stringValue = ""
        onVisibilityChanged()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        intervalPopUp = nil
        launchCheckbox = nil
        updateCheckbox = nil
        updateStatusLabel = nil
        statusLabel = nil
        visibilityChecks = []
    }
}
