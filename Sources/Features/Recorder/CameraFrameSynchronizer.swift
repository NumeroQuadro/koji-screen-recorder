import CoreMedia
import Foundation

struct CameraFrameSynchronizationMetrics: Equatable, Sendable {
    var acceptedCameraFrameCount = 0
    var selectedCameraFrameCount = 0
    var reusedCameraFrameCount = 0
    var futureCameraFrameCount = 0
    var invalidCameraTimestampCount = 0
    var regressingCameraTimestampCount = 0
    var invalidScreenTimestampCount = 0
    var nonmonotonicScreenTimestampCount = 0
    var generationChangeCount = 0
    var expiredCameraFrameCount = 0
}

/// Selects camera images at ScreenCaptureKit cadence. Screen PTS and camera PTS are host-clock
/// values; future camera frames are held, duplicate camera PTS may replace their image, and
/// regressing timestamps never replace an already selected frame.
final class CameraFrameSynchronizer: @unchecked Sendable {
    private let lock = NSLock()
    private var latestGeneration: UInt64?
    private var latestCameraTimestamp: CMTime?
    private var pendingFutureFrame: SynchronizedCameraFrame?
    private var selectedFrame: SynchronizedCameraFrame?
    private var latestScreenTimestamp: CMTime?
    private var storedMetrics = CameraFrameSynchronizationMetrics()

    func selectFrame(
        latestCameraFrame: SynchronizedCameraFrame?,
        forScreenTime screenTime: CMTime,
        maximumFrameAge: CMTime? = nil
    ) -> SynchronizedCameraFrame? {
        lock.withLock {
            guard Self.isUsable(screenTime) else {
                storedMetrics.invalidScreenTimestampCount += 1
                return nil
            }
            if let latestScreenTimestamp,
               CMTimeCompare(screenTime, latestScreenTimestamp) <= 0 {
                storedMetrics.nonmonotonicScreenTimestampCount += 1
                return nil
            }
            latestScreenTimestamp = screenTime

            promotePendingFrame(atOrBefore: screenTime)
            if let latestCameraFrame {
                ingest(latestCameraFrame, relativeTo: screenTime)
            }
            promotePendingFrame(atOrBefore: screenTime)

            guard let selectedFrame else { return nil }
            if CMTimeCompare(selectedFrame.presentationTimeStamp, screenTime) > 0 {
                storedMetrics.futureCameraFrameCount += 1
                return nil
            }
            if let maximumFrameAge,
               Self.isUsable(maximumFrameAge),
               CMTimeCompare(maximumFrameAge, .zero) >= 0 {
                let frameAge = CMTimeSubtract(screenTime, selectedFrame.presentationTimeStamp)
                if Self.isUsable(frameAge), CMTimeCompare(frameAge, maximumFrameAge) > 0 {
                    storedMetrics.expiredCameraFrameCount += 1
                    return nil
                }
            }

            if latestCameraFrame?.sampleBuffer === selectedFrame.sampleBuffer {
                storedMetrics.selectedCameraFrameCount += 1
            } else {
                storedMetrics.reusedCameraFrameCount += 1
            }
            return selectedFrame
        }
    }

    func metrics() -> CameraFrameSynchronizationMetrics {
        lock.withLock { storedMetrics }
    }

    private func ingest(
        _ frame: SynchronizedCameraFrame,
        relativeTo screenTime: CMTime
    ) {
        let timestamp = frame.presentationTimeStamp
        guard Self.isUsable(timestamp) else {
            storedMetrics.invalidCameraTimestampCount += 1
            return
        }

        if latestGeneration != frame.generation {
            if latestGeneration != nil {
                storedMetrics.generationChangeCount += 1
            }
            latestGeneration = frame.generation
            latestCameraTimestamp = nil
            pendingFutureFrame = nil
        }

        if let latestCameraTimestamp {
            let comparison = CMTimeCompare(timestamp, latestCameraTimestamp)
            if comparison < 0 {
                storedMetrics.regressingCameraTimestampCount += 1
                return
            }
        }
        latestCameraTimestamp = timestamp
        storedMetrics.acceptedCameraFrameCount += 1

        if CMTimeCompare(timestamp, screenTime) <= 0 {
            replaceSelectedFrameIfNewer(with: frame)
        } else {
            pendingFutureFrame = frame
            storedMetrics.futureCameraFrameCount += 1
        }
    }

    private func promotePendingFrame(atOrBefore screenTime: CMTime) {
        guard
            let pendingFutureFrame,
            CMTimeCompare(pendingFutureFrame.presentationTimeStamp, screenTime) <= 0
        else {
            return
        }

        replaceSelectedFrameIfNewer(with: pendingFutureFrame)
        self.pendingFutureFrame = nil
    }

    private func replaceSelectedFrameIfNewer(with frame: SynchronizedCameraFrame) {
        if let selectedFrame,
           CMTimeCompare(frame.presentationTimeStamp, selectedFrame.presentationTimeStamp) < 0 {
            storedMetrics.regressingCameraTimestampCount += 1
            return
        }
        selectedFrame = frame
    }

    private static func isUsable(_ time: CMTime) -> Bool {
        CMTIME_IS_VALID(time) && CMTIME_IS_NUMERIC(time) && time.timescale > 0
    }
}
