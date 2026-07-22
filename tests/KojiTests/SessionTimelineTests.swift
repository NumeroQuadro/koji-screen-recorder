import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Koji

final class SessionTimelineTests: XCTestCase {
    func testEpochStartsOnceAndCannotBeReplaced() {
        let timeline = SessionTimeline()
        let first = CMTime(value: 600, timescale: 600)
        let later = CMTime(value: 1_200, timescale: 600)

        XCTAssertFalse(timeline.hasStarted)
        XCTAssertEqual(timeline.startIfNeeded(at: first), first)
        XCTAssertEqual(timeline.startIfNeeded(at: later), first)
        XCTAssertEqual(timeline.epoch, first)
        XCTAssertTrue(timeline.hasStarted)
    }

    func testElapsedTimeUsesMediaTimestampsAndRejectsNegativeOrInvalidValues() throws {
        let timeline = SessionTimeline()
        timeline.startIfNeeded(at: CMTime(value: 600, timescale: 600))

        let elapsed = try XCTUnwrap(
            timeline.elapsedTime(for: CMTime(value: 1_500, timescale: 600))
        )
        XCTAssertEqual(
            elapsed,
            1.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            timeline.relativeTime(for: CMTime(value: 1_500, timescale: 600)),
            CMTime(value: 900, timescale: 600)
        )
        XCTAssertNil(timeline.elapsedTime(for: CMTime(value: 300, timescale: 600)))
        XCTAssertNil(timeline.relativeTime(for: CMTime(value: 300, timescale: 600)))
        XCTAssertNil(timeline.elapsedTime(for: .invalid))
    }

    func testElapsedTimeIsUnavailableBeforeWriterEpochStarts() {
        let timeline = SessionTimeline()
        XCTAssertNil(timeline.elapsedTime(for: .zero))
    }

    func testEncodingPipelineEstablishesTheSharedEpochFromFirstWriterReadySample() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KojiSessionTimelineTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let timeline = SessionTimeline()
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
            outputValidator: TimelineOutputValidatorStub(),
            timeline: timeline
        )
        try pipeline.startWriting()

        let firstPTS = CMTime(value: 90, timescale: 30)
        pipeline.appendVideoBuffer(try makeVideoSampleBuffer(presentationTime: firstPTS))
        _ = try await pipeline.finishWriting()

        XCTAssertEqual(timeline.epoch, firstPTS)
    }

    func testVideoEstablishesEpochRegardlessOfEarlierAudioCallbackOrder() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KojiSessionTimelineOrderTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let timeline = SessionTimeline()
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
            outputValidator: TimelineOutputValidatorStub(),
            timeline: timeline
        )
        try pipeline.startWriting()

        pipeline.appendAudioBuffer(
            try makeVideoSampleBuffer(presentationTime: CMTime(value: 30, timescale: 30))
        )
        let firstVideoPTS = CMTime(value: 60, timescale: 30)
        pipeline.appendVideoBuffer(try makeVideoSampleBuffer(presentationTime: firstVideoPTS))
        _ = try await pipeline.finishWriting()

        XCTAssertEqual(timeline.epoch, firstVideoPTS)
        XCTAssertEqual(pipeline.deliveryMetrics().systemAudioBeforeVideoEpochDropCount, 1)
    }

    func testEncodingDropsDuplicateAndRegressingVideoTimestamps() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KojiMonotonicVideoTests-\(UUID().uuidString)", isDirectory: true)
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
            outputValidator: TimelineOutputValidatorStub(),
            backpressureLimits: EncodingBackpressureLimits(
                video: 8,
                systemAudio: 8,
                microphone: 8
            )
        )
        try pipeline.startWriting()

        pipeline.appendVideoBuffer(try makeVideoSampleBuffer(presentationTime: CMTime(value: 60, timescale: 30)))
        pipeline.appendVideoBuffer(try makeVideoSampleBuffer(presentationTime: CMTime(value: 60, timescale: 30)))
        pipeline.appendVideoBuffer(try makeVideoSampleBuffer(presentationTime: CMTime(value: 45, timescale: 30)))
        pipeline.appendVideoBuffer(try makeVideoSampleBuffer(presentationTime: CMTime(value: 90, timescale: 30)))
        _ = try await pipeline.finishWriting()

        let metrics = pipeline.deliveryMetrics()
        XCTAssertEqual(metrics.appendedVideoFrameCount, 2)
        XCTAssertEqual(metrics.videoTimestampDropCount, 2)
    }

    private func makeVideoSampleBuffer(presentationTime: CMTime) throws -> CMSampleBuffer {
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
            presentationTimeStamp: presentationTime,
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

private struct TimelineOutputValidatorStub: RecordingOutputValidating {
    func validateRecording(at url: URL) async throws {}
}
