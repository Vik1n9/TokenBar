import AppKit
import WebKit

/// A visible console window used only for signing in. It shares the default
/// website data store with `QwenSession`, so cookies land where the poller
/// will find them.
@MainActor
final class LoginWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var pollTimer: Timer?
    private let onSignedIn: () -> Void

    init(onSignedIn: @escaping () -> Void) {
        self.onSignedIn = onSignedIn
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: config)
        web.load(URLRequest(url: QwenSession.consoleURL))

        let win = NSWindow(contentRect: web.frame,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered,
                           defer: false)
        win.isReleasedWhenClosed = false   // we hold the reference ourselves
        win.title = "Sign in to QwenCloud"
        win.contentView = web
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
        webView = web
        startPolling()
    }

    /// Watches for a usable `secToken`; once it appears the login is done.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSignedIn() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func checkSignedIn() {
        guard let webView else { return }
        let js = """
        try {
          const res = await fetch('/tool/user/info.json', { credentials: 'include' });
          const json = await res.json();
          return !!(json && json.data && json.data.secToken);
        } catch (e) { return false; }
        """
        Task { @MainActor [weak self] in
            let value = try? await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
            guard (value as? Bool) == true else { return }
            self?.finish()
        }
    }

    private func finish() {
        close()
        onSignedIn()
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        window = nil
        webView = nil
    }
}
