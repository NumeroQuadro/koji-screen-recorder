import AVFoundation
import CoreMedia
import Foundation
import OSLog

enum EncodingPipelineError: LocalizedError, Equatable {
    case failedToAddVideoInput
    case failedToAddAudioInput
    case failedToAddMicrophoneInput
    case notStarted
    case noMediaSamples
    case writerFailed
    case invalidOutput
    case finalizationFailed

    var errorDescription: String? {
        switch self {
        case .failedToAddVideoInput, .failedToAddAudioInput, .failedToAddMicrophoneInput, .notStarted:
            "Koji could not prepare the recording encoder."
        case .noMediaSamples:
            "No screen frames were captured. The empty recording was removed."
        case .writerFailed:
            "Koji could not finish the recording. The temporary recording was kept for recovery if possible."
        case .invalidOutput:
            "Koji could not validate the recording. The temporary recording was kept for recovery if possible."
        case .finalizationFailed:
            "Koji could not move the completed recording to its final filename. The temporary recording was kept for recovery."
        }
    }
}

final class EncodingPipeline: @unchecked Sendable {
    private static let finalizationLogger = Logger(
        subsystem: "com.koji.screenrecorder",
        category: "RecordingFinalization"
    )

    let outputURL: URL
    let temporaryURL: URL
    let includesMicrophoneTrack: Bool

    private let width: Int
    private let height: Int
    private let fileType: AVFileType
    private let videoCodec: AVVideoCodecType
    private let expectedFrameRate: Int
    private let videoBitRate: Int
    private let audioBitRate: Int
    private let videoCompositor: (any RecordingVideoCompositing)?
    private let outputValidator: any RecordingOutputValidating
    private let backpressure: EncodingBackpressureController
    private let outputRepository: RecordingOutputRepository
    private let outputDestination: RecordingOutputDestination
    private let timeline: SessionTimeline
    private let deliveryDiagnostics = EncodingDeliveryDiagnostics()
    private let firstVideoFrameGate = FirstVideoFrameGate()

    private let queue = DispatchQueue(label: "Koji.EncodingPipeline")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerSessionStarted: Bool = false
    private var finishing: Bool = false
    private var videoTimestampValidator = MonotonicTimestampValidator()
    private var systemAudioTimestampValidator = MonotonicTimestampValidator()
    private var microphoneTimestampValidator = MonotonicTimestampValidator()

    init(
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
        outputRepository: RecordingOutputRepository = RecordingOutputRepository(),
        timeline: SessionTimeline = SessionTimeline()
    ) throws {
        self.width = width
        self.height = height
        self.includesMicrophoneTrack = includesMicrophoneTrack
        self.fileType = fileType
        self.videoCodec = videoCodec
        self.expectedFrameRate = expectedFrameRate
        self.videoBitRate = videoBitRate
        self.audioBitRate = audioBitRate
        self.videoCompositor = videoCompositor
        self.outputValidator = outputValidator
        self.outputRepository = outputRepository
        self.timeline = timeline
        backpressure = EncodingBackpressureController(limits: backpressureLimits)
        let outputDestination = try outputRepository.makeDestination(
            outputDirectory: outputDirectory,
            fileExtension: fileExtension
        )
        self.outputDestination = outputDestination
        outputURL = outputDestination.outputURL
        temporaryURL = outputDestination.temporaryURL
    }

    func startWriting() throws {
        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: fileType)
        Self.configureContainerWriting(for: writer, fileType: fileType)
        Self.finalizationLogger.info(
            "result=configured stage=writer container=\(self.fileType.rawValue, privacy: .public) fragments=\(self.fileType == .mov, privacy: .public) networkOptimized=\(writer.shouldOptimizeForNetworkUse, privacy: .public)"
        )

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: expectedFrameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else { throw EncodingPipelineError.failedToAddVideoInput }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: audioBitRate,
        ]

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(audioInput) else { throw EncodingPipelineError.failedToAddAudioInput }
        writer.add(audioInput)

        var microphoneInput: AVAssetWriterInput?
        if includesMicrophoneTrack {
            let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            micInput.expectsMediaDataInRealTime = true

            guard writer.canAdd(micInput) else { throw EncodingPipelineError.failedToAddMicrophoneInput }
            writer.add(micInput)
            microphoneInput = micInput
        }

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]

        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.microphoneInput = microphoneInput
        self.pixelBufferAdaptor = pixelBufferAdaptor

        guard writer.startWriting() else {
            removeInvalidTemporaryFile()
            throw EncodingPipelineError.writerFailed
        }
    }

    static func configureContainerWriting(for writer: AVAssetWriter, fileType: AVFileType) {
        if fileType == .mov {
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            if #available(macOS 14.0, *) {
                writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            }
            writer.shouldOptimizeForNetworkUse = false
        } else {
            writer.movieFragmentInterval = .invalid
            if #available(macOS 14.0, *) {
                writer.initialMovieFragmentInterval = .invalid
            }
            writer.shouldOptimizeForNetworkUse = true
        }
    }

    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        backpressure.submit(.video, to: queue) { [weak self] in
            self?._appendVideoBuffer(sampleBuffer)
        }
    }

    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        backpressure.submit(.systemAudio, to: queue) { [weak self] in
            self?._appendAudioBuffer(sampleBuffer)
        }
    }

    func appendMicrophoneBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard includesMicrophoneTrack else { return }

        backpressure.submit(.microphone, to: queue) { [weak self] in
            self?._appendMicrophoneBuffer(sampleBuffer)
        }
    }

    func ingestionMetrics() -> EncodingBackpressureMetrics {
        backpressure.snapshot()
    }

    func deliveryMetrics() -> EncodingDeliveryMetrics {
        deliveryDiagnostics.snapshot()
    }

    func waitForFirstVideoFrame(timeout: TimeInterval) async -> Bool {
        await firstVideoFrameGate.wait(timeout: timeout)
    }

    func finishWriting() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let didEnqueue = backpressure.stopAcceptingAndEnqueue(on: queue) { [weak self] in
                guard let self else {
                    continuation.resume(throwing: EncodingPipelineError.notStarted)
                    return
                }
                self.finishing = true

                guard let writer = self.writer, let videoInput = self.videoInput, let audioInput = self.audioInput else {
                    continuation.resume(throwing: EncodingPipelineError.notStarted)
                    return
                }

                guard self.writerSessionStarted else {
                    writer.cancelWriting()
                    self.removeInvalidTemporaryFile()
                    continuation.resume(throwing: EncodingPipelineError.noMediaSamples)
                    return
                }
                guard writer.status == .writing else {
                    self.preserveNonEmptyTemporaryFileForRecoveryOrDiscard()
                    self.logWriterFailure(
                        status: writer.status.rawValue,
                        error: writer.error as NSError?,
                        stage: "beforeFinish"
                    )
                    continuation.resume(throwing: EncodingPipelineError.writerFailed)
                    return
                }

                self.logTemporaryFileSize(stage: "beforeFinish")
                videoInput.markAsFinished()
                audioInput.markAsFinished()
                self.microphoneInput?.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: EncodingPipelineError.notStarted)
                        return
                    }

                    guard self.writer?.status == .completed else {
                        self.preserveNonEmptyTemporaryFileForRecoveryOrDiscard()
                        self.logWriterFailure(
                            status: self.writer?.status.rawValue ?? -1,
                            error: self.writer?.error as NSError?,
                            stage: "finish"
                        )
                        continuation.resume(throwing: EncodingPipelineError.writerFailed)
                        return
                    }
                    self.logTemporaryFileSize(stage: "afterFinish")

                    Task {
                        do {
                            try await self.outputValidator.validateRecording(at: self.temporaryURL)
                        } catch let error as RecordingOutputValidationError {
                            self.preserveNonEmptyTemporaryFileForRecoveryOrDiscard()
                            Self.finalizationLogger.error(
                                "result=failed stage=validation reason=\(Self.logValidationReason(error), privacy: .public)"
                            )
                            continuation.resume(throwing: EncodingPipelineError.invalidOutput)
                            return
                        } catch {
                            self.preserveNonEmptyTemporaryFileForRecoveryOrDiscard()
                            Self.finalizationLogger.error(
                                "result=failed stage=validation reason=unexpected"
                            )
                            continuation.resume(throwing: EncodingPipelineError.invalidOutput)
                            return
                        }

                        do {
                            continuation.resume(returning: try self.outputRepository.finalize(self.outputDestination))
                        } catch {
                            continuation.resume(throwing: EncodingPipelineError.finalizationFailed)
                        }
                    }
                }
            }

            if !didEnqueue {
                continuation.resume(throwing: EncodingPipelineError.notStarted)
            }
        }
    }

    private func _appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing else { return }
        guard let writer, let videoInput, let pixelBufferAdaptor else { return }
        guard writer.status == .writing else { return }

        guard videoInput.isReadyForMoreMediaData else {
            deliveryDiagnostics.recordVideoInputNotReady()
            return
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            deliveryDiagnostics.recordVideoMissingImageBuffer()
            return
        }
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard videoTimestampValidator.evaluate(presentationTimeStamp) == .accepted else {
            deliveryDiagnostics.recordVideoTimestampDrop()
            return
        }

        startSessionIfNeeded(with: presentationTimeStamp, writer: writer)

        let outputPixelBuffer: CVPixelBuffer
        if let videoCompositor, let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool {
            outputPixelBuffer = videoCompositor.composite(
                screenPixelBuffer: imageBuffer,
                screenPresentationTime: presentationTimeStamp,
                destinationPool: pixelBufferPool
            ) ?? imageBuffer
        } else {
            outputPixelBuffer = imageBuffer
        }

        let didAppend = pixelBufferAdaptor.append(
            outputPixelBuffer,
            withPresentationTime: presentationTimeStamp
        )
        deliveryDiagnostics.recordVideoAppend(didAppend)
        if didAppend {
            firstVideoFrameGate.signal()
        } else if let error = writer.error {
            print("EncodingPipeline append failed: \(error)")
        }
    }

    private func _appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing else { return }
        guard let writer, let audioInput else { return }
        guard writer.status == .writing else { return }

        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // The first valid screen frame owns the recording epoch. Earlier audio callbacks are
        // intentionally dropped so callback arrival order cannot shift or precede the video timeline.
        guard writerSessionStarted, let epoch = timeline.epoch else {
            deliveryDiagnostics.recordSystemAudioTimestampDrop(beforeVideoEpoch: true)
            return
        }
        guard
            CMTimeCompare(presentationTimeStamp, epoch) >= 0,
            systemAudioTimestampValidator.evaluate(presentationTimeStamp) == .accepted
        else {
            deliveryDiagnostics.recordSystemAudioTimestampDrop(beforeVideoEpoch: false)
            return
        }
        guard audioInput.isReadyForMoreMediaData else {
            deliveryDiagnostics.recordSystemAudioInputNotReady()
            return
        }
        let didAppend = audioInput.append(sampleBuffer)
        deliveryDiagnostics.recordSystemAudioAppend(didAppend)
        if !didAppend, let error = writer.error {
            print("EncodingPipeline audio append failed: \(error)")
        }
    }

    private func _appendMicrophoneBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing else { return }
        guard let writer, let microphoneInput else { return }
        guard writer.status == .writing else { return }

        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard writerSessionStarted, let epoch = timeline.epoch else {
            deliveryDiagnostics.recordMicrophoneTimestampDrop(beforeVideoEpoch: true)
            return
        }
        guard
            CMTimeCompare(presentationTimeStamp, epoch) >= 0,
            microphoneTimestampValidator.evaluate(presentationTimeStamp) == .accepted
        else {
            deliveryDiagnostics.recordMicrophoneTimestampDrop(beforeVideoEpoch: false)
            return
        }
        guard microphoneInput.isReadyForMoreMediaData else {
            deliveryDiagnostics.recordMicrophoneInputNotReady()
            return
        }
        let didAppend = microphoneInput.append(sampleBuffer)
        deliveryDiagnostics.recordMicrophoneAppend(didAppend)
        if !didAppend, let error = writer.error {
            print("EncodingPipeline microphone append failed: \(error)")
        }
    }

    private func startSessionIfNeeded(with presentationTimeStamp: CMTime, writer: AVAssetWriter) {
        guard !writerSessionStarted else { return }
        let epoch = timeline.startIfNeeded(at: presentationTimeStamp)
        writer.startSession(atSourceTime: epoch)
        writerSessionStarted = true
    }

    private func removeInvalidTemporaryFile() {
        outputRepository.discardTemporary(outputDestination)
    }

    private func preserveNonEmptyTemporaryFileForRecoveryOrDiscard() {
        guard
            let fileSize = try? RecordingArtifactPolicy.regularFileSize(at: temporaryURL),
            fileSize > 0
        else {
            removeInvalidTemporaryFile()
            return
        }

        Self.finalizationLogger.info(
            "result=preserved stage=recovery sizeBytes=\(fileSize, privacy: .public)"
        )
    }

    private func logWriterFailure(status: Int, error: NSError?, stage: String) {
        if let error {
            Self.finalizationLogger.error(
                "result=failed stage=\(stage, privacy: .public) writerStatus=\(status, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)"
            )
        } else {
            Self.finalizationLogger.error(
                "result=failed stage=\(stage, privacy: .public) writerStatus=\(status, privacy: .public)"
            )
        }
    }

    private func logTemporaryFileSize(stage: String) {
        do {
            let fileSize = try RecordingArtifactPolicy.regularFileSize(at: temporaryURL)
            Self.finalizationLogger.info(
                "result=checked stage=\(stage, privacy: .public) sizeBytes=\(fileSize, privacy: .public)"
            )
        } catch {
            Self.finalizationLogger.error(
                "result=failed stage=\(stage, privacy: .public) reason=fileMetadata"
            )
        }
    }

    private static func logValidationReason(_ error: RecordingOutputValidationError) -> String {
        switch error {
        case .unreadableFile:
            "unreadableFile"
        case .unsafeFileType:
            "unsafeFileType"
        case .emptyFile:
            "emptyFile"
        case .unreadableMedia:
            "unreadableMedia"
        case .missingVideoTrack:
            "missingVideoTrack"
        }
    }
}
