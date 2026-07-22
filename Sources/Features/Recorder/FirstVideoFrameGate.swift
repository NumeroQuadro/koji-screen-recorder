import Foundation

final class FirstVideoFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func wait(timeout: TimeInterval) async -> Bool {
        let waiterID = UUID()

        return await withCheckedContinuation { continuation in
            let shouldResumeImmediately = lock.withLock {
                if isSignaled {
                    return true
                }
                waiters[waiterID] = continuation
                return false
            }

            if shouldResumeImmediately {
                continuation.resume(returning: true)
                return
            }

            let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            Task { [self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                resolve(waiterID: waiterID, result: false)
            }
        }
    }

    func signal() {
        let continuations = lock.withLock {
            guard !isSignaled else { return [CheckedContinuation<Bool, Never>]() }
            isSignaled = true
            let continuations = Array(waiters.values)
            waiters.removeAll()
            return continuations
        }

        continuations.forEach { $0.resume(returning: true) }
    }

    private func resolve(waiterID: UUID, result: Bool) {
        let continuation = lock.withLock {
            waiters.removeValue(forKey: waiterID)
        }
        continuation?.resume(returning: result)
    }
}
