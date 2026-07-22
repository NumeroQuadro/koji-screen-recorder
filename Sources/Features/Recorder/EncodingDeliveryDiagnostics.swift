import Foundation

struct EncodingDeliveryMetrics: Equatable, Sendable {
    var appendedVideoFrameCount = 0
    var videoInputNotReadyCount = 0
    var videoMissingImageBufferCount = 0
    var videoAppendFailureCount = 0
    var videoTimestampDropCount = 0
    var appendedSystemAudioSampleCount = 0
    var systemAudioInputNotReadyCount = 0
    var systemAudioAppendFailureCount = 0
    var systemAudioTimestampDropCount = 0
    var systemAudioBeforeVideoEpochDropCount = 0
    var appendedMicrophoneSampleCount = 0
    var microphoneInputNotReadyCount = 0
    var microphoneAppendFailureCount = 0
    var microphoneTimestampDropCount = 0
    var microphoneBeforeVideoEpochDropCount = 0
}

final class EncodingDeliveryDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics = EncodingDeliveryMetrics()

    func recordVideoInputNotReady() {
        lock.withLock { metrics.videoInputNotReadyCount += 1 }
    }

    func recordVideoMissingImageBuffer() {
        lock.withLock { metrics.videoMissingImageBufferCount += 1 }
    }

    func recordVideoAppend(_ succeeded: Bool) {
        lock.withLock {
            if succeeded {
                metrics.appendedVideoFrameCount += 1
            } else {
                metrics.videoAppendFailureCount += 1
            }
        }
    }

    func recordVideoTimestampDrop() {
        lock.withLock { metrics.videoTimestampDropCount += 1 }
    }

    func recordSystemAudioInputNotReady() {
        lock.withLock { metrics.systemAudioInputNotReadyCount += 1 }
    }

    func recordSystemAudioAppend(_ succeeded: Bool) {
        lock.withLock {
            if succeeded {
                metrics.appendedSystemAudioSampleCount += 1
            } else {
                metrics.systemAudioAppendFailureCount += 1
            }
        }
    }

    func recordSystemAudioTimestampDrop(beforeVideoEpoch: Bool) {
        lock.withLock {
            metrics.systemAudioTimestampDropCount += 1
            if beforeVideoEpoch {
                metrics.systemAudioBeforeVideoEpochDropCount += 1
            }
        }
    }

    func recordMicrophoneInputNotReady() {
        lock.withLock { metrics.microphoneInputNotReadyCount += 1 }
    }

    func recordMicrophoneAppend(_ succeeded: Bool) {
        lock.withLock {
            if succeeded {
                metrics.appendedMicrophoneSampleCount += 1
            } else {
                metrics.microphoneAppendFailureCount += 1
            }
        }
    }

    func recordMicrophoneTimestampDrop(beforeVideoEpoch: Bool) {
        lock.withLock {
            metrics.microphoneTimestampDropCount += 1
            if beforeVideoEpoch {
                metrics.microphoneBeforeVideoEpochDropCount += 1
            }
        }
    }

    func snapshot() -> EncodingDeliveryMetrics {
        lock.withLock { metrics }
    }
}
