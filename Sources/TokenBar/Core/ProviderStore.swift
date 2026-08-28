import Foundation

/// Single source of truth for what one provider's menu bar item shows.
@MainActor
final class ProviderStore {
    enum State: Equatable {
        case unknown
        /// No API key yet, or the web session is signed out.
        case needsAuth
        case ok
        case failed(String)
    }

    private(set) var state: State = .unknown
    /// Last successful reading, kept so a transient failure still shows numbers.
    private(set) var snapshot: ProviderSnapshot?
    private(set) var lastAttempt: Date?

    var onChange: (() -> Void)?

    func apply(_ snapshot: ProviderSnapshot) {
        lastAttempt = Date()
        self.snapshot = snapshot
        state = .ok
        onChange?()
    }

    func fail(_ message: String) {
        lastAttempt = Date()
        state = .failed(message)
        onChange?()
    }

    func markNeedsAuth() {
        lastAttempt = Date()
        state = .needsAuth
        snapshot = nil
        onChange?()
    }
}
