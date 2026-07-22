import CoreMedia
import CoreVideo
import XCTest
@testable import Koji

final class CameraFrameSynchronizerTests: XCTestCase {
    func testNeverSelectsAFutureFrameAndPromotesItWhenScreenCatchesUp() throws {
        let synchronizer = CameraFrameSynchronizer()
        let future = try makeFrame(time: 11, generation: 1)

        XCTAssertNil(synchronizer.selectFrame(latestCameraFrame: future, forScreenTime: time(10)))
        XCTAssertNil(synchronizer.selectFrame(latestCameraFrame: nil, forScreenTime: time(10.5)))
        XCTAssertTrue(
            synchronizer.selectFrame(latestCameraFrame: nil, forScreenTime: time(11))?.sampleBuffer
                === future.sampleBuffer
        )
    }

    func testSelectsNewestEligibleFrameAndReusesItAtScreenCadence() throws {
        let synchronizer = CameraFrameSynchronizer()
        let first = try makeFrame(time: 1, generation: 1)
        let second = try makeFrame(time: 1.05, generation: 1)

        XCTAssertTrue(
            synchronizer.selectFrame(latestCameraFrame: first, forScreenTime: time(1.01))?.sampleBuffer
                === first.sampleBuffer
        )
        XCTAssertTrue(
            synchronizer.selectFrame(latestCameraFrame: second, forScreenTime: time(1.1))?.sampleBuffer
                === second.sampleBuffer
        )
        XCTAssertTrue(
            synchronizer.selectFrame(latestCameraFrame: nil, forScreenTime: time(1.2))?.sampleBuffer
                === second.sampleBuffer
        )
        XCTAssertEqual(synchronizer.metrics().reusedCameraFrameCount, 1)
    }

    func testDuplicateReplacesButRegressionIsRejectedWithinGeneration() throws {
        let synchronizer = CameraFrameSynchronizer()
        let first = try makeFrame(time: 2, generation: 3)
        let duplicate = try makeFrame(time: 2, generation: 3)
        let regressing = try makeFrame(time: 1.9, generation: 3)

        _ = synchronizer.selectFrame(latestCameraFrame: first, forScreenTime: time(2.1))
        XCTAssertTrue(
            synchronizer.selectFrame(latestCameraFrame: duplicate, forScreenTime: time(2.2))?.sampleBuffer
                === duplicate.sampleBuffer
        )
        XCTAssertTrue(
            synchronizer.selectFrame(latestCameraFrame: regressing, forScreenTime: time(2.3))?.sampleBuffer
                === duplicate.sampleBuffer
        )
        XCTAssertEqual(synchronizer.metrics().regressingCameraTimestampCount, 1)
    }

    func testReconnectGenerationPreservesMonotonicSelectionUntilNewClockCatchesUp() throws {
        let synchronizer = CameraFrameSynchronizer()
        let previousGeneration = try makeFrame(time: 5, generation: 1)
        let reconnectBehind = try makeFrame(time: 4, generation: 2)
        let reconnectCaughtUp = try makeFrame(time: 5.15, generation: 2)

        _ = synchronizer.selectFrame(
            latestCameraFrame: previousGeneration,
            forScreenTime: time(5.05)
        )
        XCTAssertTrue(
            synchronizer.selectFrame(
                latestCameraFrame: reconnectBehind,
                forScreenTime: time(5.1)
            )?.sampleBuffer === previousGeneration.sampleBuffer
        )
        XCTAssertTrue(
            synchronizer.selectFrame(
                latestCameraFrame: reconnectCaughtUp,
                forScreenTime: time(5.2)
            )?.sampleBuffer === reconnectCaughtUp.sampleBuffer
        )
        XCTAssertEqual(synchronizer.metrics().generationChangeCount, 1)
    }

    func testInvalidAndNonmonotonicScreenTimesProduceNoSelection() throws {
        let synchronizer = CameraFrameSynchronizer()
        let frame = try makeFrame(time: 1, generation: 1)

        XCTAssertNil(synchronizer.selectFrame(latestCameraFrame: frame, forScreenTime: .invalid))
        XCTAssertNotNil(synchronizer.selectFrame(latestCameraFrame: frame, forScreenTime: time(1.1)))
        XCTAssertNil(synchronizer.selectFrame(latestCameraFrame: nil, forScreenTime: time(1.1)))
        XCTAssertNil(synchronizer.selectFrame(latestCameraFrame: nil, forScreenTime: time(1)))
        XCTAssertEqual(synchronizer.metrics().invalidScreenTimestampCount, 1)
        XCTAssertEqual(synchronizer.metrics().nonmonotonicScreenTimestampCount, 2)
    }

    func testExpiresLastFrameOnlyAfterMaximumAge() throws {
        let synchronizer = CameraFrameSynchronizer()
        let frame = try makeFrame(time: 1, generation: 1)
        let maximumAge = CMTime(seconds: 1, preferredTimescale: 600)

        XCTAssertNotNil(
            synchronizer.selectFrame(
                latestCameraFrame: frame,
                forScreenTime: time(1.1),
                maximumFrameAge: maximumAge
            )
        )
        XCTAssertNotNil(
            synchronizer.selectFrame(
                latestCameraFrame: nil,
                forScreenTime: time(2),
                maximumFrameAge: maximumAge
            )
        )
        XCTAssertNil(
            synchronizer.selectFrame(
                latestCameraFrame: nil,
                forScreenTime: time(2.01),
                maximumFrameAge: maximumAge
            )
        )
        XCTAssertEqual(synchronizer.metrics().expiredCameraFrameCount, 1)
    }

    private func makeFrame(time seconds: Double, generation: UInt64) throws -> SynchronizedCameraFrame {
        let presentationTime = time(seconds)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                2,
                2,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return SynchronizedCameraFrame(
            sampleBuffer: try XCTUnwrap(sampleBuffer),
            presentationTimeStamp: presentationTime,
            generation: generation
        )
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}
