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
    private var controllers: [ProviderController] = []
    private var refreshService: RefreshService!
    private var settingsWindow: SettingsWindowController!
    private var loginWindow: LoginWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        providers = ProviderRegistry.makeAll()

        refreshService = RefreshService { [weak self] in self?.refreshAll() }

        loginWindow = LoginWindowController { [weak self] in
            guard let self else { return }
            // The session that was live during sign-in is still the logged-out
            // one, so drop it before the next read.
            self.providers.compactMap { $0 as? QwenProvider }.forEach { $0.invalidateSession() }
            self.refreshAll()
        }

        settingsWindow = SettingsWindowController(
            refreshService: refreshService,
            providers: providers,
            onVisibilityChanged: { [weak self] in self?.rebuildControllers() }
        )

        wireProviderCallbacks()
        rebuildControllers()

        refreshService.start()
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

    /// Rebuilds the status items to match the current visibility settings.
    private func rebuildControllers() {
        controllers.forEach { $0.tearDown() }
        controllers = providers.filter(\.isVisible).map { provider in
            ProviderController(
                provider: provider,
                openSettings: { [weak self] in self?.settingsWindow.show() },
                signIn: { [weak self] _ in self?.loginWindow.show() }
            )
        }
        refreshAll()
    }

    private func refreshAll() {
        controllers.forEach { $0.refresh() }
    }
}
