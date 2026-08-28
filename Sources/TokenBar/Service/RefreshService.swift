import AppKit

/// Owns the polling cadence: a timer, plus opportunistic refreshes when the
/// machine wakes up or the network comes back.
@MainActor
final class RefreshService {
    static let intervalKey = "refreshIntervalMinutes"
    static let availableIntervals: [Int] = [1, 5, 15, 30]

    private var timer: Timer?
    private let action: () -> Void

    var intervalMinutes: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.intervalKey)
            return Self.availableIntervals.contains(stored) ? stored : 5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.intervalKey)
            start()
        }
    }

    init(action: @escaping () -> Void) {
        self.action = action
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in action() }
        }
    }

    func start() {
        timer?.invalidate()
        let seconds = TimeInterval(intervalMinutes * 60)
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.action() }
        }
        timer.tolerance = seconds * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
