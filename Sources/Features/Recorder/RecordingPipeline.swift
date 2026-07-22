import AVFoundation
import CoreMedia
import Foundation

protocol RecordingVideoFrameSink: AnyObject {
    func submitScreenFrame(_ sampleBuffer: CMSampleBuffer)
}

protocol RecordingMediaEncoding: AnyObject {
    var outputURL: URL { get }
    var temporaryURL: URL { get }
    var includesMicrophoneTrack: Bool { get }

    func startWriting() throws
    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer)
    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer)
    func appendMicrophoneBuffer(_ sampleBuffer: CMSampleBuffer)
    func ingestionMetrics() -> EncodingBackpressureMetrics
    func deliveryMetrics() -> EncodingDeliveryMetrics
    func waitForFirstVideoFrame(timeout: TimeInterval) async -> Bool
    func finishWriting() async throws -> URL
}

extension EncodingPipeline: RecordingMediaEncoding {}

final class RecordingPipeline: @unchecked Sendable, RecordingVideoFrameSink {
    private let encoder: any RecordingMediaEncoding
    let timeline: SessionTimeline

    var outputURL: URL { encoder.outputURL }
    var temporaryURL: URL { encoder.temporaryURL }
    var includesMicrophoneTrack: Bool { encoder.includesMicrophoneTrack }

    init(encoder: any RecordingMediaEncoding, timeline: SessionTimeline) {
        self.encoder = encoder
        self.timeline = timeline
    }

    convenience init(
        width: Int,
        height: Int,
        includesMicrophoneTrack: Bool,
        outputDirectory: URL,
        fileType: AVFileType,
        fileExtension: String,
        videoCodec: AVVideoCodecType,
        expectedFrameRate: Int,
        videoBitRate: Int,
        audioBitRate: Int,
        videoCompositor: (any RecordingVideoCompositing)? = nil,
        outputValidator: any RecordingOutputValidating = RecordingOutputValidator(),
        backpressureLimits: EncodingBackpressureLimits = .production,
        outputRepository: RecordingOutputRepository = RecordingOutputRepository()
    ) throws {
        let timeline = SessionTimeline()
        let encoder = try EncodingPipeline(
            width: width,
            height: height,
            includesMicrophoneTrack: includesMicrophoneTrack,
            outputDirectory: outputDirectory,
            fileType: fileType,
            fileExtension: fileExtension,
            videoCodec: videoCodec,
            expectedFrameRate: expectedFrameRate,
            videoBitRate: videoBitRate,
            audioBitRate: audioBitRate,
            videoCompositor: videoCompositor,
            outputValidator: outputValidator,
            backpressureLimits: backpressureLimits,
            outputRepository: outputRepository,
            timeline: timeline
        )
        self.init(encoder: encoder, timeline: timeline)
    }

    func startWriting() throws {
        try encoder.startWriting()
    }

    func submitScreenFrame(_ sampleBuffer: CMSampleBuffer) {
        encoder.appendVideoBuffer(sampleBuffer)
    }

    func submitSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        encoder.appendAudioBuffer(sampleBuffer)
    }

    func submitMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard includesMicrophoneTrack else { return }
        encoder.appendMicrophoneBuffer(sampleBuffer)
    }

    func elapsedTime(for sampleBuffer: CMSampleBuffer) -> TimeInterval? {
        timeline.elapsedTime(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func ingestionMetrics() -> EncodingBackpressureMetrics {
        encoder.ingestionMetrics()
    }

    func deliveryMetrics() -> EncodingDeliveryMetrics {
        encoder.deliveryMetrics()
    }

    func waitForFirstVideoFrame(timeout: TimeInterval) async -> Bool {
        await encoder.waitForFirstVideoFrame(timeout: timeout)
    }

    func finishWriting() async throws -> URL {
        try await encoder.finishWriting()
    }
}
