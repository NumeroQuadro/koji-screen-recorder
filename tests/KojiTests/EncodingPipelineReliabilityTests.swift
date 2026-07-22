import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import Koji

final class EncodingPipelineReliabilityTests: XCTestCase {
    func testContainerSpecificWriterConfiguration() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KojiWriterConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let movWriter = try AVAssetWriter(
            outputURL: outputDirectory.appendingPathComponent("fragmented.mov"),
            fileType: .mov
        )
        EncodingPipeline.configureContainerWriting(for: movWriter, fileType: .mov)

        XCTAssertEqual(movWriter.movieFragmentInterval.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(movWriter.initialMovieFragmentInterval.seconds, 1, accuracy: 0.001)
        XCTAssertFalse(movWriter.shouldOptimizeForNetworkUse)

        let mp4Writer = try AVAssetWriter(
            outputURL: outputDirectory.appendingPathComponent("fast-start.mp4"),
            fileType: .mp4
        )
        EncodingPipeline.configureContainerWriting(for: mp4Writer, fileType: .mp4)

        XCTAssertFalse(mp4Writer.movieFragmentInterval.isValid)
        XCTAssertFalse(mp4Writer.initialMovieFragmentInterval.isValid)
        XCTAssertTrue(mp4Writer.shouldOptimizeForNetworkUse)
    }

    func testSyntheticScreenFramesFinalizeAsPlayableVideo() async throws {
        try await assertSyntheticScreenFramesFinalize(
            fileType: .mov,
            fileExtension: "mov",
            frameCount: 30,
            frameDelay: nil
        )
    }

    func testSyntheticScreenFramesFinalizeAsPlayableMP4() async throws {
        try await assertSyntheticScreenFramesFinalize(
            fileType: .mp4,
            fileExtension: "mp4",
            frameCount: 90,
            frameDelay: .milliseconds(25)
        )
    }

    private func assertSyntheticScreenFramesFinalize(
        fileType: AVFileType,
        fileExtension: String,
        frameCount: Int,
        frameDelay: Duration?
    ) async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KojiEncodingReliabilityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let pipeline = try EncodingPipeline(
            width: 64,
            height: 64,
            includesMicrophoneTrack: false,
            outputDirectory: outputDirectory,
            fileType: fileType,
            fileExtension: fileExtension,
            videoCodec: .h264,
            expectedFrameRate: 30,
            videoBitRate: 500_000,
            audioBitRate: 96_000,
            backpressureLimits: EncodingBackpressureLimits(video: 8, systemAudio: 8, microphone: 8)
        )
        try pipeline.startWriting()

        for frameIndex in 0..<frameCount {
            pipeline.appendVideoBuffer(
                try makeVideoSampleBuffer(
                    presentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: 30)
                )
            )
            if let frameDelay {
                try await Task.sleep(for: frameDelay)
            }
        }

        let didReceiveFirstVideoFrame = await pipeline.waitForFirstVideoFrame(timeout: 1)
        XCTAssertTrue(didReceiveFirstVideoFrame)

        let outputURL = try await pipeline.finishWriting()
        try await RecordingOutputValidator().validateRecording(at: outputURL)

        let values = try outputURL.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertGreaterThan(values.fileSize ?? 0, 0)
        XCTAssertGreaterThan(pipeline.ingestionMetrics().video.acceptedSampleCount, 0)
    }

    func testValidationFailurePreservesNonEmptyTemporaryRecordingForRecovery() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KojiEncodingRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let pipeline = try EncodingPipeline(
            width: 64,
            height: 64,
            includesMicrophoneTrack: false,
            outputDirectory: outputDirectory,
            fileType: .mov,
            fileExtension: "mov",
            videoCodec: .h264,
            expectedFrameRate: 30,
            videoBitRate: 500_000,
            audioBitRate: 96_000,
            outputValidator: RejectingRecordingOutputValidator(),
            backpressureLimits: EncodingBackpressureLimits(video: 8, systemAudio: 8, microphone: 8)
        )
        try pipeline.startWriting()

        for frameIndex in 0..<30 {
            pipeline.appendVideoBuffer(
                try makeVideoSampleBuffer(
                    presentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: 30)
                )
            )
        }

        let didReceiveFirstVideoFrame = await pipeline.waitForFirstVideoFrame(timeout: 1)
        XCTAssertTrue(didReceiveFirstVideoFrame)

        do {
            _ = try await pipeline.finishWriting()
            XCTFail("Expected validation failure")
        } catch let error as EncodingPipelineError {
            XCTAssertEqual(error, .invalidOutput)
        }

        let values = try pipeline.temporaryURL.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pipeline.temporaryURL.path))
        XCTAssertGreaterThan(values.fileSize ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pipeline.outputURL.path))
    }

    private func makeVideoSampleBuffer(presentationTime: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let pixelBufferStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary,
            &pixelBuffer
        )
        guard pixelBufferStatus == kCVReturnSuccess, let pixelBuffer else {
            throw EncodingReliabilityTestError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0x44, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var formatDescription: CMVideoFormatDescription?
        let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard descriptionStatus == noErr, let formatDescription else {
            throw EncodingReliabilityTestError.formatDescriptionCreationFailed
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw EncodingReliabilityTestError.sampleBufferCreationFailed
        }
        return sampleBuffer
    }
}

private enum EncodingReliabilityTestError: Error {
    case pixelBufferCreationFailed
    case formatDescriptionCreationFailed
    case sampleBufferCreationFailed
}

private struct RejectingRecordingOutputValidator: RecordingOutputValidating {
    func validateRecording(at url: URL) async throws {
        throw RecordingOutputValidationError.unreadableMedia
    }
}
