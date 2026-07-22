import Foundation

struct LatestValueMailboxMetrics: Equatable, Sendable {
    let acceptedCount: UInt64
    let replacementCount: UInt64
    let currentCount: Int
    let peakCount: Int
}

final class LatestValueMailbox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var acceptedCount: UInt64 = 0
    private var replacementCount: UInt64 = 0
    private var peakCount: Int = 0

    @discardableResult
    func replace(with newValue: Value) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        let previousValue = value
        if previousValue != nil {
            replacementCount += 1
        }
        value = newValue
        acceptedCount += 1
        peakCount = max(peakCount, 1)
        return previousValue
    }

    func latest() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func takeLatest() -> Value? {
        lock.lock()
        defer { lock.unlock() }

        let latestValue = value
        value = nil
        return latestValue
    }

    func clear() {
        lock.lock()
        value = nil
        lock.unlock()
    }

    func metrics() -> LatestValueMailboxMetrics {
        lock.lock()
        defer { lock.unlock() }

        return LatestValueMailboxMetrics(
            acceptedCount: acceptedCount,
            replacementCount: replacementCount,
            currentCount: value == nil ? 0 : 1,
            peakCount: peakCount
        )
    }
}
