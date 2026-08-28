import AppKit
import UserNotifications

/// A release newer than the running build.
struct UpdateInfo: Equatable {
    /// Display form, without the tag's `v` prefix: `1.2.0`.
    let version: String
    /// The release page, opened in the browser when the user asks for it.
    let url: URL
}

/// A dotted release version, compared numerically rather than as text so
/// `1.10.0` sorts above `1.9.0`.
///
/// Anything after a `-` (`1.2.0-beta.1`) is a pre-release suffix: it is dropped
/// for comparison and a pre-release therefore never counts as newer than the
/// same numbers released. Missing components read as zero, so `1.2` == `1.2.0`.
struct AppVersion: Comparable {
    let components: [Int]

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let dash = text.firstIndex(of: "-") { text = String(text[text.startIndex..<dash]) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part.prefix(while: \.isNumber)), value >= 0 else { return nil }
            numbers.append(value)
        }
        components = numbers
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// True only when both versions parse and `latest` is strictly ahead.
    /// An unparsable tag never triggers an update prompt.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let latest = AppVersion(latest), let current = AppVersion(current) else { return false }
        return current < latest
    }
}

/// The subset of the GitHub release payload this app reads.
private struct ReleasePayload: Decodable {
    let tagName: String
    let htmlUrl: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case draft
        case prerelease
    }
}

private enum UpdateError: LocalizedError {
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "GitHub returned HTTP \(code)"
        }
    }
}

/// Watches the project's GitHub releases and says when a newer one exists.
///
/// It only ever tells the user; nothing is downloaded, replaced or installed
/// behind their back. The menu grows one row pointing at the release page, and
/// a notification is posted once per version so a running app is not nagged on
/// every check.
@MainActor
final class UpdateChecker {
    static let enabledKey = "updates.checkAutomatically"
    private static let notifiedVersionKey = "updates.notifiedVersion"
    private static let lastCheckKey = "updates.lastCheckedAt"

    /// One check a day is plenty for a hobby release cadence, and it keeps the
    /// app from hitting GitHub on every wake-from-sleep.
    static let checkInterval: TimeInterval = 24 * 3600

    static let releasesAPI = URL(string: "https://api.github.com/repos/Vik1n9/TokenBar/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/Vik1n9/TokenBar/releases/latest")!

    /// `CFBundleShortVersionString`, or `0.0.0` when running the bare binary
    /// outside an app bundle (`--self-check`), where updates are meaningless.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// nil until a check finds something newer than the running build.
    private(set) var available: UpdateInfo?
    /// Human-readable outcome of the last check, for the Settings pane.
    private(set) var status: String = ""

    var onChange: (() -> Void)?

    private var checkTask: Task<Void, Never>?
    private var timer: Timer?

    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { start() } else { stop() }
        }
    }

    private var lastCheckedAt: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastCheckKey) }
    }

    /// The version the user has already been notified about, so the alert fires
    /// once per release rather than once per check.
    private var notifiedVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.notifiedVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.notifiedVersionKey) }
    }

    /// Starts the schedule: an immediate check if one is due, then an hourly
    /// tick that only reaches the network once a day.
    func start() {
        stop()
        guard isEnabled else { return }
        requestAuthorizationIfNeeded()

        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        checkIfDue()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        checkTask?.cancel()
        checkTask = nil
    }

    /// Hourly tick: only actually hits the network once a day.
    private func checkIfDue() {
        guard isEnabled else { return }
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    /// `userInitiated` checks report failures in Settings; the scheduled ones
    /// stay quiet, because a laptop that is offline is not a problem to report.
    func check(userInitiated: Bool) {
        checkTask?.cancel()
        checkTask = Task { @MainActor in
            if userInitiated {
                status = "Checking…"
                onChange?()
            }
            do {
                let release = try await Self.fetchLatestRelease(currentVersion: Self.currentVersion)
                if Task.isCancelled { return }
                lastCheckedAt = Date()
                apply(release, userInitiated: userInitiated)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                if userInitiated {
                    status = "Check failed: \(error.localizedDescription)"
                    onChange?()
                }
            }
        }
    }

    private func apply(_ release: UpdateInfo?, userInitiated: Bool) {
        let previous = available
        available = release

        if let release {
            status = "Version \(release.version) is available."
            if notifiedVersion != release.version {
                notifiedVersion = release.version
                post(version: release.version)
            }
        } else {
            status = "TokenBar \(Self.currentVersion) is up to date."
        }

        if previous != available || userInitiated { onChange?() }
    }

    // MARK: - Network

    /// Returns the latest release when it is newer than the running build, or
    /// nil when the app is current. Drafts and pre-releases are ignored.
    private static func fetchLatestRelease(currentVersion: String) async throws -> UpdateInfo? {
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TokenBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.badStatus(http.statusCode)
        }
        let release = try JSONDecoder().decode(ReleasePayload.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        guard AppVersion.isNewer(release.tagName, than: currentVersion) else { return nil }

        let url = URL(string: release.htmlUrl) ?? releasesPage
        var version = release.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return UpdateInfo(version: version, url: url)
    }

    // MARK: - Notification

    private func requestAuthorizationIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(version: String) {
        // Notifications need a real bundle; `--self-check` runs the bare binary.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "TokenBar \(version) is available"
        content.body = "You are on \(Self.currentVersion). Open the menu to download it — nothing is installed automatically."
        let request = UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
