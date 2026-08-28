import AppKit

/// Qwen's page in the Settings window. The console session is the credential,
/// so there is nothing to type here — only sign in, sign out, open console.
@MainActor
final class QwenSettingsPane: NSView {
    private let provider: QwenProvider

    init(provider: QwenProvider) {
        self.provider = provider
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func build() {
        let blurb = NSTextField(wrappingLabelWithString:
            "Reads your Token Plan through a signed-in console session. Sign in once; the session is reused until you sign out.")
        blurb.frame = NSRect(x: 0, y: 132, width: 380, height: 48)
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = .secondaryLabelColor
        blurb.isSelectable = false

        let signIn = NSButton(title: "Sign In…", target: self, action: #selector(signInTapped))
        signIn.bezelStyle = .rounded
        signIn.frame = NSRect(x: -2, y: 96, width: 110, height: 30)

        let signOut = NSButton(title: "Sign Out", target: self, action: #selector(signOutTapped))
        signOut.bezelStyle = .rounded
        signOut.frame = NSRect(x: 112, y: 96, width: 110, height: 30)

        let console = NSButton(title: "Open Console", target: self, action: #selector(openConsoleTapped))
        console.bezelStyle = .rounded
        console.frame = NSRect(x: 226, y: 96, width: 130, height: 30)

        [blurb, signIn, signOut, console].forEach { addSubview($0) }
    }

    @objc private func signInTapped() {
        provider.onSignInRequested?()
    }

    @objc private func signOutTapped() {
        Task { @MainActor in
            await provider.signOut()
            provider.onRefreshRequested?()
        }
    }

    @objc private func openConsoleTapped() {
        NSWorkspace.shared.open(QwenSession.consoleURL)
    }
}
