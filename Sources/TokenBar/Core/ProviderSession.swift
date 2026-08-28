import Foundation

/// One provider's live state and its in-flight refresh. Owns no UI: the single
/// menu bar item reads every session and draws them together.
@MainActor
final class ProviderSession {
    let provider: Provider
    let store = ProviderStore()

    private var refreshTask: Task<Void, Never>?

    init(provider: Provider) {
        self.provider = provider
    }

    var onChange: (() -> Void)? {
        get { store.onChange }
        set { store.onChange = newValue }
    }

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

    func signOut() {
        refreshTask?.cancel()
        Task { @MainActor in
            await provider.signOut()
            store.markNeedsAuth()
        }
    }

    func cancel() {
        refreshTask?.cancel()
    }

    /// What this provider contributes to the shared menu bar title.
    var segment: MenuBarSegment {
        switch store.state {
        case .unknown:
            return MenuBarSegment(glyph: provider.glyph, text: "…", severity: .normal)
        case .needsAuth:
            return MenuBarSegment(glyph: provider.glyph, text: "—", severity: .normal)
        case .failed:
            // Keep the last good numbers; the warning sign says they are stale.
            if let snapshot = store.snapshot {
                return MenuBarSegment(glyph: provider.glyph, text: "\(snapshot.barText) ⚠", severity: .stale)
            }
            return MenuBarSegment(glyph: provider.glyph, text: "⚠", severity: .stale)
        case .ok:
            guard let snapshot = store.snapshot else {
                return MenuBarSegment(glyph: provider.glyph, text: "—", severity: .normal)
            }
            return MenuBarSegment(glyph: provider.glyph,
                                  text: snapshot.barText,
                                  severity: snapshot.severity == .warning ? .warning : .normal)
        }
    }
}
