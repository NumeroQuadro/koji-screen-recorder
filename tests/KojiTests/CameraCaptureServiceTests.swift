import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import Koji

final class CameraCaptureServiceTests: XCTestCase {
    func testFormatSelectorChoosesHighestSupportedFormatWithin1080p30Cap() {
        let selection = CameraFormatSelector.select(from: [
            CameraFormatCandidate(
                formatIndex: 0,
                width: 3_840,
                height: 2_160,
                minimumFrameRate: 1,
                maximumFrameRate: 60
            ),
            CameraFormatCandidate(
                formatIndex: 1,
                width: 1_280,
                height: 720,
                minimumFrameRate: 1,
                maximumFrameRate: 60
            ),
            CameraFormatCandidate(
                formatIndex: 2,
                width: 1_920,
                height: 1_080,
                minimumFrameRate: 1,
                maximumFrameRate: 60
            ),
            CameraFormatCandidate(
                formatIndex: 3,
                width: 1_920,
                height: 1_080,
                minimumFrameRate: 60,
                maximumFrameRate: 120
            ),
        ])

        XCTAssertEqual(
            selection,
            CameraFormatSelection(
                formatIndex: 2,
                width: 1_920,
                height: 1_080,
                frameRate: 30
            )
        )
    }

    func testFormatSelectorSupportsPortraitAndLowerFrameRateDevices() {
        let selection = CameraFormatSelector.select(from: [
            CameraFormatCandidate(
                formatIndex: 4,
                width: 1_080,
                height: 1_920,
                minimumFrameRate: 1,
                maximumFrameRate: 24
            ),
        ])

        XCTAssertEqual(selection?.width, 1_080)
        XCTAssertEqual(selection?.height, 1_920)
        XCTAssertEqual(selection?.frameRate, 24)
    }

    func testFormatSelectorRejectsFormatsAboveBound() {
        XCTAssertNil(
            CameraFormatSelector.select(from: [
                CameraFormatCandidate(
                    formatIndex: 0,
                    width: 2_560,
                    height: 1_440,
                    minimumFrameRate: 1,
                    maximumFrameRate: 30
                ),
            ])
        )
    }

    func testPreviewAndRecordingConsumersReuseOneRunningSession() async throws {
        let backend = CameraCaptureBackendSpy()
        let service = CameraCaptureService(backend: backend)

        _ = try await service.startPreview(deviceID: "iphone")
        _ = try await service.startRecording(deviceID: "iphone")

        XCTAssertEqual(backend.configuredDeviceIDs, ["iphone"])
        XCTAssertEqual(backend.startCount, 1)

        await service.stopPreview()
        XCTAssertEqual(backend.stopCount, 0)
        XCTAssertEqual(backend.tearDownCount, 0)

        await service.stopRecording()
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(backend.tearDownCount, 1)
    }

    func testSwitchingDeviceReconfiguresWithoutStartingDuplicateSession() async throws {
        let backend = CameraCaptureBackendSpy()
        let service = CameraCaptureService(backend: backend)

        _ = try await service.startPreview(deviceID: "built-in")
        _ = try await service.startPreview(deviceID: "iphone")

        XCTAssertEqual(backend.configuredDeviceIDs, ["built-in", "iphone"])
        XCTAssertEqual(backend.startCount, 1)

        await service.stopPreview()
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testFailedStartRollsBackDemandAndTearsDown() async {
        let backend = CameraCaptureBackendSpy()
        backend.startError = .failedToStart
        let service = CameraCaptureService(backend: backend)

        do {
            _ = try await service.startPreview(deviceID: "busy")
            XCTFail("Expected camera start to fail")
        } catch {
            XCTAssertEqual(error as? CameraCaptureError, .failedToStart)
        }

        XCTAssertEqual(backend.stopCount, 0)
        XCTAssertEqual(backend.tearDownCount, 1)
    }

    func testLatestValueMailboxNeverRetainsMoreThanOneValue() {
        let mailbox = LatestValueMailbox<FrameProbe>()
        let first = FrameProbe(id: 1)
        let second = FrameProbe(id: 2)

        mailbox.replace(with: first)
        let replacedValue = mailbox.replace(with: second)
        XCTAssertTrue(replacedValue === first)
        XCTAssertTrue(mailbox.latest() === second)
        XCTAssertEqual(
            mailbox.metrics(),
            LatestValueMailboxMetrics(
                acceptedCount: 2,
                replacementCount: 1,
                currentCount: 1,
                peakCount: 1
            )
        )

        XCTAssertTrue(mailbox.takeLatest() === second)
        XCTAssertEqual(mailbox.metrics().currentCount, 0)
    }

    func testSessionNotificationsPublishNonfatalCaptureEvents() {
        let backend = CameraCaptureBackendSpy()
        let service = CameraCaptureService(backend: backend)
        let expectation = expectation(description: "interruption event")
        let receivedEvents = LatestValueMailbox<CameraCaptureEvent>()
        service.setEventHandler { event in
            receivedEvents.replace(with: event)
            expectation.fulfill()
        }

        NotificationCenter.default.post(
            name: AVCaptureSession.wasInterruptedNotification,
            object: backend.previewSession
        )

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(receivedEvents.latest(), .interrupted)
    }

    func testLatestFrameUsesInjectedClockConversionAndGeneration() throws {
        let backend = CameraCaptureBackendSpy()
        backend.frameGeneration = 7
        let mailbox = LatestValueMailbox<CMSampleBuffer>()
        mailbox.replace(with: try makeVideoSampleBuffer(
            presentationTime: CMTime(seconds: 2, preferredTimescale: 600)
        ))
        let service = CameraCaptureService(
            backend: backend,
            mailbox: mailbox,
            timestampConverter: OffsetCameraTimestampConverter(offset: 5)
        )

        let frame = try XCTUnwrap(service.latestFrame())

        XCTAssertEqual(frame.generation, 7)
        XCTAssertEqual(CMTimeGetSeconds(frame.presentationTimeStamp), 7, accuracy: 0.000_001)
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
        return try XCTUnwrap(sampleBuffer)
    }
}

private struct OffsetCameraTimestampConverter: CameraTimestampConverting {
    let offset: TimeInterval

    func convertToHostTime(_ time: CMTime, from sourceClock: CMClock) -> CMTime? {
        CMTimeAdd(time, CMTime(seconds: offset, preferredTimescale: 600))
    }
}

private final class FrameProbe {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

private final class CameraCaptureBackendSpy: CameraCaptureBackend {
    let previewSession = AVCaptureSession()
    var synchronizationClock: CMClock? = CMClockGetHostTimeClock()
    var frameGeneration: UInt64 = 1
    private(set) var configuredDeviceIDs: [String] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var tearDownCount = 0
    var startError: CameraCaptureError?
    var isRunning = false

    func configure(deviceID: String) throws -> CameraCaptureFormat {
        configuredDeviceIDs.append(deviceID)
        return CameraCaptureFormat(
            deviceID: deviceID,
            width: 1_920,
            height: 1_080,
            frameRate: 30
        )
    }

    func startRunning() throws {
        startCount += 1
        if let startError {
            throw startError
        }
        isRunning = true
    }

    func stopRunning() {
        stopCount += 1
        isRunning = false
    }

    func tearDown() {
        tearDownCount += 1
    }
}
