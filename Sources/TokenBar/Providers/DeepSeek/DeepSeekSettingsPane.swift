import AppKit

/// DeepSeek's page in the Settings window: the API key, plus the knobs that
/// change how the balance is read and displayed.
@MainActor
final class DeepSeekSettingsPane: NSView {
    private let provider: DeepSeekProvider

    private let keyField = NSSecureTextField(frame: NSRect(x: 96, y: 162, width: 200, height: 22))
    private let statusLabel = NSTextField(labelWithString: "")
    private let baseURLField = NSTextField(frame: NSRect(x: 96, y: 130, width: 260, height: 22))
    private let currencyPopUp = NSPopUpButton(frame: NSRect(x: 96, y: 66, width: 120, height: 26), pullsDown: false)
    private let thresholdField = NSTextField(frame: NSRect(x: 96, y: 36, width: 80, height: 22))
    private let displayPopUp = NSPopUpButton(frame: NSRect(x: 96, y: 2, width: 220, height: 26), pullsDown: false)

    private let currencyChoices = ["Auto", "CNY", "USD"]

    init(provider: DeepSeekProvider) {
        self.provider = provider
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        build()
        sync()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func build() {
        addSubview(label("API Key", y: 164))
        keyField.placeholderString = "sk-…"
        addSubview(keyField)

        let save = NSButton(title: "Validate & Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.frame = NSRect(x: 300, y: 158, width: 78, height: 30)
        save.toolTip = "Checks the key against the balance endpoint before storing it in the keychain."
        addSubview(save)

        addSubview(label("Endpoint", y: 132))
        baseURLField.placeholderString = APIClient.defaultBaseURL
        baseURLField.target = self
        baseURLField.action = #selector(baseURLChanged)
        addSubview(baseURLField)

        statusLabel.frame = NSRect(x: 0, y: 100, width: 380, height: 20)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        addSubview(statusLabel)

        addSubview(label("Currency", y: 70))
        currencyPopUp.addItems(withTitles: currencyChoices)
        currencyPopUp.target = self
        currencyPopUp.action = #selector(currencyChanged)
        currencyPopUp.toolTip = "Wallets are never converted. If the chosen currency is absent, the real one is shown with its ISO code."
        addSubview(currencyPopUp)

        addSubview(label("Warn below", y: 38))
        thresholdField.target = self
        thresholdField.action = #selector(thresholdChanged)
        addSubview(thresholdField)

        addSubview(label("Menu bar", y: 6))
        displayPopUp.addItems(withTitles: ["Balance only", "Balance and today's spend"])
        displayPopUp.target = self
        displayPopUp.action = #selector(displayModeChanged)
        addSubview(displayPopUp)
    }

    private func label(_ text: String, y: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: 0, y: y, width: 90, height: 18)
        field.alignment = .right
        return field
    }

    private func sync() {
        keyField.stringValue = ""
        keyField.placeholderString = provider.isConfigured ? "•••••••• (stored)" : "sk-…"
        baseURLField.stringValue = UserDefaults.standard.string(forKey: "deepseek.baseURL") ?? ""
        currencyPopUp.selectItem(withTitle: provider.preferredCurrency ?? "Auto")
        thresholdField.stringValue = Money.amount(provider.lowBalanceThreshold)
        displayPopUp.selectItem(at: provider.displayMode == .balanceAndToday ? 1 : 0)
        statusLabel.stringValue = provider.isConfigured ? "Key stored in the login keychain." : "No key yet."
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        let candidate = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            statusLabel.stringValue = "Paste a key first."
            return
        }
        statusLabel.stringValue = "Checking…"
        Task { @MainActor in
            do {
                try await provider.validateAndSave(candidate)
                keyField.stringValue = ""
                sync()
                statusLabel.stringValue = "Key validated and saved."
                provider.onRefreshRequested?()
            } catch {
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func baseURLChanged() {
        let value = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(value, forKey: "deepseek.baseURL")
        provider.onRefreshRequested?()
    }

    @objc private func currencyChanged() {
        let title = currencyPopUp.titleOfSelectedItem ?? "Auto"
        provider.preferredCurrency = title == "Auto" ? nil : title
        provider.onRefreshRequested?()
    }

    @objc private func thresholdChanged() {
        provider.lowBalanceThreshold = Money.parse(thresholdField.stringValue)
        thresholdField.stringValue = Money.amount(provider.lowBalanceThreshold)
        provider.onRefreshRequested?()
    }

    @objc private func displayModeChanged() {
        provider.displayMode = displayPopUp.indexOfSelectedItem == 1 ? .balanceAndToday : .balanceOnly
        provider.onRefreshRequested?()
    }
}
