import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import XCTest
@testable import Koji

final class FacecamRecordingIntegrationTests: XCTestCase {
    func testCompositorEncoderAndTwoAudioTracksFinalizeAsPlayableMovie() async throws {
        try await assertCompositorEncoderAndTwoAudioTracksFinalize(
            fileType: .mov,
            fileExtension: "mov"
        )
    }

    func testCompositorEncoderAndTwoAudioTracksFinalizeAsPlayableMP4() async throws {
        try await assertCompositorEncoderAndTwoAudioTracksFinalize(
            fileType: .mp4,
            fileExtension: "mp4"
        )
    }

    private func assertCompositorEncoderAndTwoAudioTracksFinalize(
        fileType: AVFileType,
        fileExtension: String
    ) async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KojiFacecamIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let cameraBuffer = try makePixelBuffer(width: 80, height: 45, color: .red)
        let cameraFrame = try makeVideoSampleBuffer(
            pixelBuffer: cameraBuffer,
            presentationTime: .zero,
            frameRate: 30
        )
        let cameraProvider = IntegrationCameraFrameProvider(
            frame: SynchronizedCameraFrame(
                sampleBuffer: cameraFrame,
                presentationTimeStamp: .zero,
                generation: 1
            )
        )
        let compositor = FacecamVideoCompositor(
            cameraFrameProvider: cameraProvider,
            placementStore: FacecamPlacementStore(
                initialPlacement: FacecamPlacement(
                    normalizedCenterX: 0.5,
                    normalizedCenterY: 0.5,
                    sizePreset: .medium
                )
            ),
            displayGeometry: SelectedDisplayCaptureGeometry(
                displayID: 1,
                frameInScreenPoints: CGRect(x: 0, y: 0, width: 320, height: 180),
                pointPixelScale: 1
            ),
            outputPixelSize: CapturePixelSize(width: 320, height: 180),
            context: CIContext(options: [.useSoftwareRenderer: true])
        )
        let pipeline = try EncodingPipeline(
            width: 320,
            height: 180,
            includesMicrophoneTrack: true,
            outputDirectory: outputDirectory,
            fileType: fileType,
            fileExtension: fileExtension,
            videoCodec: .h264,
            expectedFrameRate: 30,
            videoBitRate: 1_000_000,
            audioBitRate: 96_000,
            videoCompositor: compositor,
            backpressureLimits: EncodingBackpressureLimits(
                video: 32,
                systemAudio: 64,
                microphone: 64
            )
        )
        try pipeline.startWriting()

        for frameIndex in 0..<15 {
            let screenBuffer = try makePixelBuffer(width: 320, height: 180, color: .blue)
            pipeline.appendVideoBuffer(
                try makeVideoSampleBuffer(
                    pixelBuffer: screenBuffer,
                    presentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: 30),
                    frameRate: 30
                )
            )
        }
        for chunkIndex in 0..<50 {
            let presentationTime = CMTime(value: CMTimeValue(chunkIndex * 480), timescale: 48_000)
            pipeline.appendAudioBuffer(try makeAudioSampleBuffer(presentationTime: presentationTime))
            pipeline.appendMicrophoneBuffer(try makeAudioSampleBuffer(presentationTime: presentationTime))
        }

        let didReceiveFirstVideoFrame = await pipeline.waitForFirstVideoFrame(timeout: 2)
        XCTAssertTrue(didReceiveFirstVideoFrame)
        let outputURL = try await pipeline.finishWriting()
        try await RecordingOutputValidator().validateRecording(at: outputURL)

        let asset = AVURLAsset(url: outputURL)
        let isPlayable = try await asset.load(.isPlayable)
        let videoTrackCount = try await asset.loadTracks(withMediaType: .video).count
        let audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertTrue(isPlayable)
        XCTAssertEqual(videoTrackCount, 1)
        XCTAssertEqual(audioTrackCount, 2)
        XCTAssertGreaterThan(duration, 0.4)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let (decodedFrame, _) = try await generator.image(
            at: CMTime(seconds: 0.25, preferredTimescale: 600)
        )
        let bitmap = NSBitmapImageRep(cgImage: decodedFrame)
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
            .usingColorSpace(.deviceRGB)
        let background = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10))
            .usingColorSpace(.deviceRGB)

        XCTAssertGreaterThan(try XCTUnwrap(center).redComponent, 0.65)
        XCTAssertLessThan(try XCTUnwrap(center).blueComponent, 0.35)
        XCTAssertGreaterThan(try XCTUnwrap(background).blueComponent, 0.65)
        XCTAssertLessThan(try XCTUnwrap(background).redComponent, 0.35)
        XCTAssertGreaterThan(compositor.metrics().composedFrameCount, 0)
        XCTAssertLessThanOrEqual(pipeline.ingestionMetrics().video.peakPendingSampleCount, 32)
        XCTAssertLessThanOrEqual(pipeline.ingestionMetrics().systemAudio.peakPendingSampleCount, 64)
        XCTAssertLessThanOrEqual(pipeline.ingestionMetrics().microphone.peakPendingSampleCount, 64)
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        color: IntegrationPixelColor
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = baseAddress + y * bytesPerRow + x * 4
                pixel[0] = color.blue
                pixel[1] = color.green
                pixel[2] = color.red
                pixel[3] = 255
            }
        }
        return buffer
    }

    private func makeVideoSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        frameRate: Int32
    ) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: frameRate),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private func makeAudioSampleBuffer(presentationTime: CMTime) throws -> CMSampleBuffer {
        let frameCount = 480
        let channelCount = 2
        let bytesPerSample = MemoryLayout<Int16>.size
        let bytesPerFrame = channelCount * bytesPerSample
        let dataSize = frameCount * bytesPerFrame

        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &streamDescription,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataSize,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataSize,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let block = try XCTUnwrap(blockBuffer)
        let silence = [UInt8](repeating: 0, count: dataSize)
        XCTAssertEqual(
            silence.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!,
                    blockBuffer: block,
                    offsetIntoDestination: 0,
                    dataLength: dataSize
                )
            },
            kCMBlockBufferNoErr
        )

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleCount: frameCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }
}

private final class IntegrationCameraFrameProvider: CameraFrameProviding, @unchecked Sendable {
    private let frame: SynchronizedCameraFrame

    init(frame: SynchronizedCameraFrame) {
        self.frame = frame
    }

    func latestFrame() -> SynchronizedCameraFrame? {
        frame
    }
}

private struct IntegrationPixelColor {
    let blue: UInt8
    let green: UInt8
    let red: UInt8

    static let blue = IntegrationPixelColor(blue: 255, green: 0, red: 0)
    static let red = IntegrationPixelColor(blue: 0, green: 0, red: 255)
}
