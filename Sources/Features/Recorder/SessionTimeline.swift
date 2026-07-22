import CoreMedia
import Foundation

final class SessionTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEpoch: CMTime?

    var epoch: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return storedEpoch
    }

    var hasStarted: Bool {
        epoch != nil
    }

    @discardableResult
    func startIfNeeded(at presentationTime: CMTime) -> CMTime {
        lock.lock()
        defer { lock.unlock() }

        if let storedEpoch {
            return storedEpoch
        }
        storedEpoch = presentationTime
        return presentationTime
    }

    func elapsedTime(for presentationTime: CMTime) -> TimeInterval? {
        guard let relativeTime = relativeTime(for: presentationTime) else { return nil }
        let elapsed = CMTimeGetSeconds(relativeTime)
        guard elapsed.isFinite else { return nil }
        return elapsed
    }

    func relativeTime(for presentationTime: CMTime) -> CMTime? {
        lock.lock()
        let epoch = storedEpoch
        lock.unlock()

        guard let epoch else { return nil }
        guard
            CMTIME_IS_VALID(presentationTime),
            CMTIME_IS_NUMERIC(presentationTime),
            CMTimeCompare(presentationTime, epoch) >= 0
        else {
            return nil
        }
        return CMTimeSubtract(presentationTime, epoch)
    }
}
