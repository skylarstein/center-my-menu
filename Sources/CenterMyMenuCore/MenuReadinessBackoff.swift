import Foundation

/// A delay cap, deliberately not an attempt cap. A slowly launching active app can
/// become ready at any time. The owner handles lifecycle suspension and cancellation.
public struct MenuReadinessBackoff {
    private let initialDelay: TimeInterval
    private let maximumDelay: TimeInterval
    private var nextDelay: TimeInterval

    public init(initialDelay: TimeInterval = 0.25, maximumDelay: TimeInterval = 0.5) {
        precondition(initialDelay.isFinite && initialDelay > 0)
        precondition(maximumDelay.isFinite && maximumDelay >= initialDelay)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.nextDelay = initialDelay
    }

    public mutating func reset() { nextDelay = initialDelay }

    public mutating func delay(after batch: MenuBatch) -> TimeInterval? {
        let retry: Bool
        switch batch.status {
        case .empty, .unavailable, .timedOut:
            retry = true
        case .ok, .truncated:
            // A nonempty safety-limited menu is usable; rereading it indefinitely
            // cannot remove its safety limit. An empty root is not ready yet.
            retry = batch.entries.isEmpty
        case .loading, .permissionRequired, .uiTestData:
            retry = false
        }
        guard retry else {
            reset()
            return nil
        }
        let delay = nextDelay
        nextDelay = min(maximumDelay, delay * 2)
        return delay
    }
}
