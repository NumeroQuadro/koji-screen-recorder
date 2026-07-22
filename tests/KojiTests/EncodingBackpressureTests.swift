import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Koji

final class EncodingBackpressureTests: XCTestCase {
    func testEachMediaStreamDropsBeforeExceedingItsLimit() {
        let controller = EncodingBackpressureController(
            limits: EncodingBackpressureLimits(video: 2, systemAudio: 3, microphone: 4)
        )
        let queue = DispatchQueue(label: "EncodingBackpressureTests.saturation")
        queue.suspend()

        for _ in 0..<2 {
            XCTAssertTrue(controller.submit(.video, to: queue) {})
        }
        XCTAssertFalse(controller.submit(.video, to: queue) {})

        for _ in 0..<3 {
            XCTAssertTrue(controller.submit(.systemAudio, to: queue) {})
        }
        XCTAssertFalse(controller.submit(.systemAudio, to: queue) {})

        for _ in 0..<4 {
            XCTAssertTrue(controller.submit(.microphone, to: queue) {})
        }
        XCTAssertFalse(controller.submit(.microphone, to: queue) {})

        let saturated = controller.snapshot()
        XCTAssertEqual(saturated.video.pendingSampleCount, 2)
        XCTAssertEqual(saturated.video.peakPendingSampleCount, 2)
        XCTAssertEqual(saturated.video.droppedSampleCount, 1)
        XCTAssertEqual(saturated.systemAudio.pendingSampleCount, 3)
        XCTAssertEqual(saturated.systemAudio.peakPendingSampleCount, 3)
        XCTAssertEqual(saturated.systemAudio.droppedSampleCount, 1)
        XCTAssertEqual(saturated.microphone.pendingSampleCount, 4)
        XCTAssertEqual(saturated.microphone.peakPendingSampleCount, 4)
        XCTAssertEqual(saturated.microphone.droppedSampleCount, 1)

        queue.resume()
        queue.sync {}

        let drained = controller.snapshot()
        XCTAssertEqual(drained.video.pendingSampleCount, 0)
        XCTAssertEqual(drained.systemAudio.pendingSampleCount, 0)
        XCTAssertEqual(drained.microphone.pendingSampleCount, 0)
    }

    func testCapacityReturnsAfterAcceptedOperationCompletes() {
        let controller = EncodingBackpressureController(
            limits: EncodingBackpressureLimits(video: 1, systemAudio: 1, microphone: 1)
        )
        let queue = DispatchQueue(label: "EncodingBackpressureTests.readmission")
        queue.suspend()

        XCTAssertTrue(controller.submit(.video, to: queue) {})
        XCTAssertFalse(controller.submit(.video, to: queue) {})

        queue.resume()
        queue.sync {}

        XCTAssertTrue(controller.submit(.video, to: queue) {})
        queue.sync {}

        let metrics = controller.snapshot().video
        XCTAssertEqual(metrics.acceptedSampleCount, 2)
        XCTAssertEqual(metrics.droppedSampleCount, 1)
        XCTAssertEqual(metrics.pendingSampleCount, 0)
        XCTAssertEqual(metrics.peakPendingSampleCount, 1)
    }

    func testFinishBarrierFollowsAcceptedWorkAndRejectsLaterSamples() {
        let controller = EncodingBackpressureController(
            limits: EncodingBackpressureLimits(video: 1, systemAudio: 1, microphone: 1)
        )
        let queue = DispatchQueue(label: "EncodingBackpressureTests.finish")
        let events = LockedEventRecorder()
        queue.suspend()

        XCTAssertTrue(
            controller.submit(.video, to: queue) {
                events.append("video")
            }
        )
        XCTAssertTrue(
            controller.stopAcceptingAndEnqueue(on: queue) {
                events.append("finish")
            }
        )
        XCTAssertFalse(controller.submit(.systemAudio, to: queue) {})
        XCTAssertFalse(controller.stopAcceptingAndEnqueue(on: queue) {})

        queue.resume()
        queue.sync {}

        XCTAssertEqual(events.values, ["video", "finish"])
        let metrics = controller.snapshot()
        XCTAssertFalse(metrics.isAcceptingSamples)
        XCTAssertEqual(metrics.video.pendingSampleCount, 0)
        XCTAssertEqual(metrics.systemAudio.droppedSampleCount, 1)
    }

    func testConcurrentProducerStressNeverExceedsConfiguredBound() {
        let controller = EncodingBackpressureController(
            limits: EncodingBackpressureLimits(video: 2, systemAudio: 1, microphone: 1)
        )
        let queue = DispatchQueue(label: "EncodingBackpressureTests.concurrent")
        queue.suspend()

        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            controller.submit(.video, to: queue) {}
        }

        let saturated = controller.snapshot().video
        XCTAssertEqual(saturated.acceptedSampleCount, 2)
        XCTAssertEqual(saturated.droppedSampleCount, 9_998)
        XCTAssertEqual(saturated.pendingSampleCount, 2)
        XCTAssertEqual(saturated.peakPendingSampleCount, 2)

        queue.resume()
        queue.sync {}
        XCTAssertEqual(controller.snapshot().video.pendingSampleCount, 0)
    }

    func testPipelineWithoutMicrophoneTrackDoesNotRetainUnexpectedMicrophoneSample() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KojiBackpressureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let pipeline = try EncodingPipeline(
            width: 2,
            height: 2,
            includesMicrophoneTrack: false,
            outputDirectory: outputDirectory,
            fileType: .mp4,
            fileExtension: "mp4",
            videoCodec: .h264,
            expectedFrameRate: 30,
            videoBitRate: 250_000,
            audioBitRate: 96_000,
            backpressureLimits: EncodingBackpressureLimits(video: 1, systemAudio: 1, microphone: 1)
        )

        pipeline.appendMicrophoneBuffer(try makeVideoSampleBuffer())

        let microphone = pipeline.ingestionMetrics().microphone
        XCTAssertEqual(microphone.acceptedSampleCount, 0)
        XCTAssertEqual(microphone.droppedSampleCount, 0)
        XCTAssertEqual(microphone.pendingSampleCount, 0)
        XCTAssertEqual(microphone.peakPendingSampleCount, 0)
    }

    private func makeVideoSampleBuffer() throws -> CMSampleBuffer {
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
        let unwrappedPixelBuffer = try XCTUnwrap(pixelBuffer)

        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: unwrappedPixelBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        let unwrappedFormatDescription = try XCTUnwrap(formatDescription)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: unwrappedPixelBuffer,
                formatDescription: unwrappedFormatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }
}

private final class LockedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: String) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}
