import CoreMedia
import Foundation
import ScreenCaptureKit

enum ScreenCaptureSampleDisposition: Equatable, Sendable {
    case usable
    case invalid
    case dataNotReady
    case missingImageBuffer
    case missingFrameStatus
    case nonComplete(SCFrameStatus)
    case unknownFrameStatus
}

enum ScreenCaptureSampleClassifier {
    static func classify(_ sampleBuffer: CMSampleBuffer) -> ScreenCaptureSampleDisposition {
        let statusRawValue: Int?
        if
            let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentArray.first
        {
            statusRawValue = attachments[.status] as? Int
        } else {
            statusRawValue = nil
        }

        return classify(
            isValid: CMSampleBufferIsValid(sampleBuffer),
            isDataReady: CMSampleBufferDataIsReady(sampleBuffer),
            hasImageBuffer: CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
            statusRawValue: statusRawValue
        )
    }

    static func classify(
        isValid: Bool,
        isDataReady: Bool,
        hasImageBuffer: Bool,
        statusRawValue: Int?
    ) -> ScreenCaptureSampleDisposition {
        guard isValid else { return .invalid }
        guard isDataReady else { return .dataNotReady }
        guard hasImageBuffer else { return .missingImageBuffer }
        guard let statusRawValue else { return .missingFrameStatus }
        let knownStatusRawValues = [
            SCFrameStatus.complete.rawValue,
            SCFrameStatus.idle.rawValue,
            SCFrameStatus.blank.rawValue,
            SCFrameStatus.suspended.rawValue,
            SCFrameStatus.started.rawValue,
            SCFrameStatus.stopped.rawValue,
        ]
        guard knownStatusRawValues.contains(statusRawValue) else {
            return .unknownFrameStatus
        }
        guard let status = SCFrameStatus(rawValue: statusRawValue) else {
            return .unknownFrameStatus
        }
        guard status == .complete else { return .nonComplete(status) }
        return .usable
    }
}

struct CaptureSampleMetrics: Equatable, Sendable {
    var screenCallbackCount = 0
    var forwardedScreenFrameCount = 0
    var invalidScreenSampleCount = 0
    var dataNotReadyScreenSampleCount = 0
    var missingImageBufferCount = 0
    var missingFrameStatusCount = 0
    var unknownFrameStatusCount = 0
    var idleScreenFrameCount = 0
    var blankScreenFrameCount = 0
    var suspendedScreenFrameCount = 0
    var startedScreenFrameCount = 0
    var stoppedScreenFrameCount = 0
    var systemAudioCallbackCount = 0
    var microphoneCallbackCount = 0
}

final class CaptureSampleDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics = CaptureSampleMetrics()

    func reset() {
        lock.withLock {
            metrics = CaptureSampleMetrics()
        }
    }

    func recordScreen(_ disposition: ScreenCaptureSampleDisposition) {
        lock.withLock {
            metrics.screenCallbackCount += 1
            switch disposition {
            case .usable:
                metrics.forwardedScreenFrameCount += 1
            case .invalid:
                metrics.invalidScreenSampleCount += 1
            case .dataNotReady:
                metrics.dataNotReadyScreenSampleCount += 1
            case .missingImageBuffer:
                metrics.missingImageBufferCount += 1
            case .missingFrameStatus:
                metrics.missingFrameStatusCount += 1
            case .unknownFrameStatus:
                metrics.unknownFrameStatusCount += 1
            case let .nonComplete(status):
                switch status {
                case .idle:
                    metrics.idleScreenFrameCount += 1
                case .blank:
                    metrics.blankScreenFrameCount += 1
                case .suspended:
                    metrics.suspendedScreenFrameCount += 1
                case .started:
                    metrics.startedScreenFrameCount += 1
                case .stopped:
                    metrics.stoppedScreenFrameCount += 1
                case .complete:
                    break
                @unknown default:
                    metrics.unknownFrameStatusCount += 1
                }
            }
        }
    }

    func recordSystemAudio() {
        lock.withLock {
            metrics.systemAudioCallbackCount += 1
        }
    }

    func recordMicrophone() {
        lock.withLock {
            metrics.microphoneCallbackCount += 1
        }
    }

    func snapshot() -> CaptureSampleMetrics {
        lock.withLock { metrics }
    }
}
