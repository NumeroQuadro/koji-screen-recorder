import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Koji

final class RecordingPipelineTests: XCTestCase {
    func testCompositionReadyVideoSinkAndAudioMethodsForwardToEncoder() throws {
        let encoder = RecordingMediaEncoderStub(includesMicrophoneTrack: true)
        let timeline = SessionTimeline()
        let pipeline = RecordingPipeline(encoder: encoder, timeline: timeline)
        let sampleBuffer = try makeVideoSampleBuffer()
        let videoSink: any RecordingVideoFrameSink = pipeline

        videoSink.submitScreenFrame(sampleBuffer)
        pipeline.submitSystemAudio(sampleBuffer)
        pipeline.submitMicrophone(sampleBuffer)

        XCTAssertEqual(encoder.videoSampleCount, 1)
        XCTAssertEqual(encoder.systemAudioSampleCount, 1)
        XCTAssertEqual(encoder.microphoneSampleCount, 1)
    }

    func testMicrophoneSubmissionIsSkippedWhenWriterHasNoMicrophoneTrack() throws {
        let encoder = RecordingMediaEncoderStub(includesMicrophoneTrack: false)
        let pipeline = RecordingPipeline(encoder: encoder, timeline: SessionTimeline())

        pipeline.submitMicrophone(try makeVideoSampleBuffer())

        XCTAssertEqual(encoder.microphoneSampleCount, 0)
    }

    func testLifecycleOutputAndMetricsForwardToEncoder() async throws {
        let encoder = RecordingMediaEncoderStub(includesMicrophoneTrack: false)
        let pipeline = RecordingPipeline(encoder: encoder, timeline: SessionTimeline())

        try pipeline.startWriting()
        let finalizedURL = try await pipeline.finishWriting()

        XCTAssertTrue(encoder.didStartWriting)
        XCTAssertTrue(encoder.didFinishWriting)
        XCTAssertEqual(pipeline.outputURL, encoder.outputURL)
        XCTAssertEqual(pipeline.temporaryURL, encoder.temporaryURL)
        XCTAssertEqual(finalizedURL, encoder.outputURL)
        XCTAssertEqual(pipeline.ingestionMetrics(), encoder.metrics)
        XCTAssertEqual(pipeline.deliveryMetrics(), encoder.delivery)
        let didReceiveFirstVideoFrame = await pipeline.waitForFirstVideoFrame(timeout: 0.01)
        XCTAssertTrue(didReceiveFirstVideoFrame)
    }

    func testElapsedTimeReadsTheSharedSessionTimeline() throws {
        let timeline = SessionTimeline()
        timeline.startIfNeeded(at: .zero)
        let pipeline = RecordingPipeline(
            encoder: RecordingMediaEncoderStub(includesMicrophoneTrack: false),
            timeline: timeline
        )

        let elapsed = try XCTUnwrap(
            pipeline.elapsedTime(for: makeVideoSampleBuffer(presentationTime: CMTime(value: 45, timescale: 30)))
        )
        XCTAssertEqual(elapsed, 1.5, accuracy: 0.000_001)
    }

    private func makeVideoSampleBuffer(
        presentationTime: CMTime = .zero
    ) throws -> CMSampleBuffer {
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

private final class RecordingMediaEncoderStub: RecordingMediaEncoding {
    let outputURL = URL(fileURLWithPath: "/tmp/KojiRecordingPipelineTests.mp4")
    let temporaryURL = URL(fileURLWithPath: "/tmp/KojiRecordingPipelineTests.recording.mp4")
    let includesMicrophoneTrack: Bool
    let metrics = EncodingBackpressureMetrics(
        isAcceptingSamples: false,
        video: .init(
            acceptedSampleCount: 1,
            droppedSampleCount: 2,
            pendingSampleCount: 0,
            peakPendingSampleCount: 1
        ),
        systemAudio: .init(
            acceptedSampleCount: 3,
            droppedSampleCount: 4,
            pendingSampleCount: 0,
            peakPendingSampleCount: 2
        ),
        microphone: .init(
            acceptedSampleCount: 0,
            droppedSampleCount: 0,
            pendingSampleCount: 0,
            peakPendingSampleCount: 0
        )
    )
    let delivery = EncodingDeliveryMetrics(appendedVideoFrameCount: 1)

    private(set) var videoSampleCount = 0
    private(set) var systemAudioSampleCount = 0
    private(set) var microphoneSampleCount = 0
    private(set) var didStartWriting = false
    private(set) var didFinishWriting = false

    init(includesMicrophoneTrack: Bool) {
        self.includesMicrophoneTrack = includesMicrophoneTrack
    }

    func startWriting() throws {
        didStartWriting = true
    }

    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        videoSampleCount += 1
    }

    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        systemAudioSampleCount += 1
    }

    func appendMicrophoneBuffer(_ sampleBuffer: CMSampleBuffer) {
        microphoneSampleCount += 1
    }

    func ingestionMetrics() -> EncodingBackpressureMetrics {
        metrics
    }

    func deliveryMetrics() -> EncodingDeliveryMetrics {
        delivery
    }

    func waitForFirstVideoFrame(timeout: TimeInterval) async -> Bool {
        true
    }

    func finishWriting() async throws -> URL {
        didFinishWriting = true
        return outputURL
    }
}
