import Foundation

enum EncodingMediaKind: CaseIterable, Hashable, Sendable {
    case video
    case systemAudio
    case microphone
}

struct EncodingBackpressureLimits: Equatable, Sendable {
    static let production = EncodingBackpressureLimits(
        video: 2,
        systemAudio: 8,
        microphone: 8
    )

    let video: Int
    let systemAudio: Int
    let microphone: Int

    init(video: Int, systemAudio: Int, microphone: Int) {
        precondition(video > 0)
        precondition(systemAudio > 0)
        precondition(microphone > 0)

        self.video = video
        self.systemAudio = systemAudio
        self.microphone = microphone
    }

    fileprivate subscript(kind: EncodingMediaKind) -> Int {
        switch kind {
        case .video:
            video
        case .systemAudio:
            systemAudio
        case .microphone:
            microphone
        }
    }
}

struct EncodingBackpressureMetrics: Equatable, Sendable {
    struct Stream: Equatable, Sendable {
        let acceptedSampleCount: Int
        let droppedSampleCount: Int
        let pendingSampleCount: Int
        let peakPendingSampleCount: Int
    }

    let isAcceptingSamples: Bool
    let video: Stream
    let systemAudio: Stream
    let microphone: Stream
}

final class EncodingBackpressureController: @unchecked Sendable {
    private struct MutableStream {
        var acceptedSampleCount = 0
        var droppedSampleCount = 0
        var pendingSampleCount = 0
        var peakPendingSampleCount = 0

        var snapshot: EncodingBackpressureMetrics.Stream {
            EncodingBackpressureMetrics.Stream(
                acceptedSampleCount: acceptedSampleCount,
                droppedSampleCount: droppedSampleCount,
                pendingSampleCount: pendingSampleCount,
                peakPendingSampleCount: peakPendingSampleCount
            )
        }
    }

    private let limits: EncodingBackpressureLimits
    private let lock = NSLock()
    private var isAcceptingSamples = true
    private var streams = Dictionary(
        uniqueKeysWithValues: EncodingMediaKind.allCases.map { ($0, MutableStream()) }
    )

    init(limits: EncodingBackpressureLimits = .production) {
        self.limits = limits
    }

    @discardableResult
    func submit(
        _ kind: EncodingMediaKind,
        to queue: DispatchQueue,
        operation: @escaping () -> Void
    ) -> Bool {
        lock.lock()

        guard isAcceptingSamples else {
            recordDrop(for: kind)
            lock.unlock()
            return false
        }

        var stream = streams[kind] ?? MutableStream()
        guard stream.pendingSampleCount < limits[kind] else {
            stream.droppedSampleCount += 1
            streams[kind] = stream
            lock.unlock()
            return false
        }

        stream.acceptedSampleCount += 1
        stream.pendingSampleCount += 1
        stream.peakPendingSampleCount = max(
            stream.peakPendingSampleCount,
            stream.pendingSampleCount
        )
        streams[kind] = stream

        queue.async { [self] in
            defer { complete(kind) }
            operation()
        }

        lock.unlock()
        return true
    }

    @discardableResult
    func stopAcceptingAndEnqueue(
        on queue: DispatchQueue,
        operation: @escaping () -> Void
    ) -> Bool {
        lock.lock()

        guard isAcceptingSamples else {
            lock.unlock()
            return false
        }

        isAcceptingSamples = false
        queue.async {
            operation()
        }
        lock.unlock()
        return true
    }

    func snapshot() -> EncodingBackpressureMetrics {
        lock.lock()
        defer { lock.unlock() }

        return EncodingBackpressureMetrics(
            isAcceptingSamples: isAcceptingSamples,
            video: streamSnapshot(for: .video),
            systemAudio: streamSnapshot(for: .systemAudio),
            microphone: streamSnapshot(for: .microphone)
        )
    }

    private func complete(_ kind: EncodingMediaKind) {
        lock.lock()
        defer { lock.unlock() }

        var stream = streams[kind] ?? MutableStream()
        assert(stream.pendingSampleCount > 0)
        if stream.pendingSampleCount > 0 {
            stream.pendingSampleCount -= 1
        }
        streams[kind] = stream
    }

    private func recordDrop(for kind: EncodingMediaKind) {
        var stream = streams[kind] ?? MutableStream()
        stream.droppedSampleCount += 1
        streams[kind] = stream
    }

    private func streamSnapshot(for kind: EncodingMediaKind) -> EncodingBackpressureMetrics.Stream {
        (streams[kind] ?? MutableStream()).snapshot
    }
}
