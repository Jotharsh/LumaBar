import Foundation

/// Rate-limits a stream of updates (e.g. a slider drag) to one per `interval`.
/// The newest value is always the one that gets sent, and `flush` sends it immediately.
@MainActor
final class Throttler {
    private let interval: TimeInterval
    private var lastFire = Date.distantPast
    private var pending: (() -> Void)?
    private var timer: Task<Void, Never>?

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    func submit(_ action: @escaping () -> Void) {
        pending = action
        let wait = interval - Date().timeIntervalSince(lastFire)
        if wait <= 0 {
            fire()
        } else if timer == nil {
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.fire()
            }
        }
    }

    /// Sends right now, replacing anything still waiting. Used for the final value when a drag ends.
    func flush(_ action: @escaping () -> Void) {
        timer?.cancel()
        timer = nil
        pending = nil
        lastFire = Date()
        action()
    }

    private func fire() {
        timer?.cancel()
        timer = nil
        lastFire = Date()
        let action = pending
        pending = nil
        action?()
    }
}
