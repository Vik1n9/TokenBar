import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            SelfCheck.run()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var providers: [Provider] = []
    private var sessions: [ProviderSession] = []
    private var menuBar: MenuBarController!
    private var refreshService: RefreshService!
    private var updateChecker: UpdateChecker!
    private var settingsWindow: SettingsWindowController!
    private var loginWindow: LoginWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        providers = ProviderRegistry.makeAll()
        sessions = providers.map { ProviderSession(provider: $0) }
        sessions.forEach { session in
            session.onChange = { [weak self] in self?.menuBar?.render() }
        }

        refreshService = RefreshService { [weak self] in self?.refreshAll() }
        updateChecker = UpdateChecker()

        loginWindow = LoginWindowController { [weak self] in
            guard let self else { return }
            // The session that was live during sign-in is still the logged-out
            // one, so drop it before the next read.
            self.providers.compactMap { $0 as? QwenProvider }.forEach { $0.invalidateSession() }
            self.refreshAll()
        }

        settingsWindow = SettingsWindowController(
            refreshService: refreshService,
            updateChecker: updateChecker,
            providers: providers,
            onVisibilityChanged: { [weak self] in self?.applyVisibility() }
        )

        wireProviderCallbacks()

        menuBar = MenuBarController(
            sessions: visibleSessions(),
            refreshAll: { [weak self] in self?.refreshAll() },
            openSettings: { [weak self] in self?.settingsWindow.show() },
            signIn: { [weak self] _ in self?.loginWindow.show() }
        )

        // The menu is rebuilt each time it opens, so handing the controller the
        // current answer is all the update banner needs.
        updateChecker.onChange = { [weak self] in
            guard let self else { return }
            self.menuBar.pendingUpdate = self.updateChecker.available
            self.settingsWindow.updateStatusChanged()
        }
        menuBar.pendingUpdate = updateChecker.available

        refreshService.start()
        updateChecker.start()
        refreshAll()
    }

    /// Providers ask the shell for the things they do not own: the login window
    /// and an out-of-band refresh after a settings change.
    private func wireProviderCallbacks() {
        for provider in providers {
            if let qwen = provider as? QwenProvider {
                qwen.onSignInRequested = { [weak self] in self?.loginWindow.show() }
                qwen.onRefreshRequested = { [weak self] in self?.refreshAll() }
            }
            if let deepseek = provider as? DeepSeekProvider {
                deepseek.onRefreshRequested = { [weak self] in self?.refreshAll() }
            }
        }
    }

    private func visibleSessions() -> [ProviderSession] {
        sessions.filter { $0.provider.isVisible }
    }

    /// A hidden provider drops out of the shared title and menu, and stops being
    /// polled — nothing is torn down, so unhiding it costs one refresh.
    private func applyVisibility() {
        sessions.filter { !$0.provider.isVisible }.forEach { $0.cancel() }
        menuBar.setSessions(visibleSessions())
        refreshAll()
    }

    private func refreshAll() {
        visibleSessions().forEach { $0.refresh() }
    }
}
