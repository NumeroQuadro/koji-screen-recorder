import CoreImage
import CoreMedia
import CoreVideo
import XCTest
@testable import Koji

final class FacecamVideoCompositorTests: XCTestCase {
    func testCompositesUnmirroredAspectFillCameraInsideRoundedPlacement() throws {
        let outputSize = CapturePixelSize(width: 400, height: 300)
        let placement = FacecamPlacement(
            normalizedCenterX: 0.5,
            normalizedCenterY: 0.5,
            sizePreset: .small
        )
        let placementStore = FacecamPlacementStore(initialPlacement: placement)
        let screen = try makePixelBuffer(width: 400, height: 300) { _, _ in .blue }
        let camera = try makePixelBuffer(width: 80, height: 40) { x, _ in
            x < 40 ? .red : .green
        }
        let frame = try makeFrame(pixelBuffer: camera, time: 1, generation: 1)
        let frameProvider = CameraFrameProviderStub(frame: frame)
        let compositor = FacecamVideoCompositor(
            cameraFrameProvider: frameProvider,
            placementStore: placementStore,
            displayGeometry: SelectedDisplayCaptureGeometry(
                displayID: 1,
                frameInScreenPoints: CGRect(x: -400, y: 180, width: 400, height: 300),
                pointPixelScale: 2
            ),
            outputPixelSize: outputSize,
            context: CIContext(options: [.useSoftwareRenderer: true])
        )

        let result = try XCTUnwrap(
            compositor.composite(
                screenPixelBuffer: screen,
                screenPresentationTime: time(1.1),
                destinationPool: try makePool(width: 400, height: 300)
            )
        )
        let mappedRect = try mappedRect(placement: placement, outputSize: outputSize)

        XCTAssertEqual(try color(atX: 10, y: 10, in: result), .blue)
        XCTAssertEqual(
            try color(
                atX: Int(mappedRect.minX + mappedRect.width * 0.25),
                y: Int(mappedRect.midY),
                in: result
            ),
            .red
        )
        XCTAssertEqual(
            try color(
                atX: Int(mappedRect.minX + mappedRect.width * 0.75),
                y: Int(mappedRect.midY),
                in: result
            ),
            .green
        )
        XCTAssertEqual(
            try color(
                atX: Int(mappedRect.minX + 1),
                y: Int(mappedRect.minY + 1),
                in: result
            ),
            .blue
        )
        XCTAssertEqual(compositor.metrics().composedFrameCount, 1)
    }

    func testReadsLatestPlacementForEveryScreenFrameWithoutRestarting() throws {
        let outputSize = CapturePixelSize(width: 400, height: 300)
        let firstPlacement = FacecamPlacement(
            normalizedCenterX: 0.25,
            normalizedCenterY: 0.25,
            sizePreset: .small
        )
        let secondPlacement = FacecamPlacement(
            normalizedCenterX: 0.75,
            normalizedCenterY: 0.75,
            sizePreset: .small
        )
        let placementStore = FacecamPlacementStore(initialPlacement: firstPlacement)
        let screen = try makePixelBuffer(width: 400, height: 300) { _, _ in .blue }
        let camera = try makePixelBuffer(width: 40, height: 40) { _, _ in .red }
        let provider = CameraFrameProviderStub(
            frame: try makeFrame(pixelBuffer: camera, time: 1, generation: 1)
        )
        let compositor = FacecamVideoCompositor(
            cameraFrameProvider: provider,
            placementStore: placementStore,
            displayGeometry: SelectedDisplayCaptureGeometry(
                displayID: 1,
                frameInScreenPoints: CGRect(x: 0, y: 0, width: 400, height: 300),
                pointPixelScale: 1
            ),
            outputPixelSize: outputSize,
            context: CIContext(options: [.useSoftwareRenderer: true])
        )
        let pool = try makePool(width: 400, height: 300)

        let first = try XCTUnwrap(
            compositor.composite(
                screenPixelBuffer: screen,
                screenPresentationTime: time(1.1),
                destinationPool: pool
            )
        )
        placementStore.set(secondPlacement)
        let second = try XCTUnwrap(
            compositor.composite(
                screenPixelBuffer: screen,
                screenPresentationTime: time(1.2),
                destinationPool: pool
            )
        )
        let firstRect = try mappedRect(placement: firstPlacement, outputSize: outputSize)
        let secondRect = try mappedRect(placement: secondPlacement, outputSize: outputSize)

        XCTAssertEqual(try color(atX: Int(firstRect.midX), y: Int(firstRect.midY), in: first), .red)
        XCTAssertEqual(try color(atX: Int(firstRect.midX), y: Int(firstRect.midY), in: second), .blue)
        XCTAssertEqual(try color(atX: Int(secondRect.midX), y: Int(secondRect.midY), in: second), .red)
        XCTAssertEqual(compositor.metrics().composedFrameCount, 2)
    }

    func testReturnsScreenOnlyWhenNoEligibleCameraFrameExists() throws {
        let compositor = FacecamVideoCompositor(
            cameraFrameProvider: CameraFrameProviderStub(frame: nil),
            placementStore: FacecamPlacementStore(),
            displayGeometry: SelectedDisplayCaptureGeometry(
                displayID: 1,
                frameInScreenPoints: CGRect(x: 0, y: 0, width: 400, height: 300),
                pointPixelScale: 1
            ),
            outputPixelSize: CapturePixelSize(width: 400, height: 300),
            context: CIContext(options: [.useSoftwareRenderer: true])
        )

        let result = compositor.composite(
            screenPixelBuffer: try makePixelBuffer(width: 400, height: 300) { _, _ in .blue },
            screenPresentationTime: time(1),
            destinationPool: try makePool(width: 400, height: 300)
        )

        XCTAssertNil(result)
        XCTAssertEqual(compositor.metrics().screenOnlyFrameCount, 1)
    }

    func testKeepsLastFrameForAtMostOneSecondThenRecoversWithoutRestart() throws {
        let screen = try makePixelBuffer(width: 400, height: 300) { _, _ in .blue }
        let camera = try makePixelBuffer(width: 40, height: 40) { _, _ in .red }
        let provider = CameraFrameProviderStub(
            frame: try makeFrame(pixelBuffer: camera, time: 1, generation: 1)
        )
        let events = FacecamEventRecorder()
        let compositor = FacecamVideoCompositor(
            cameraFrameProvider: provider,
            placementStore: FacecamPlacementStore(),
            displayGeometry: SelectedDisplayCaptureGeometry(
                displayID: 1,
                frameInScreenPoints: CGRect(x: 0, y: 0, width: 400, height: 300),
                pointPixelScale: 1
            ),
            outputPixelSize: CapturePixelSize(width: 400, height: 300),
            context: CIContext(options: [.useSoftwareRenderer: true]),
            onEvent: { event in events.record(event) }
        )
        let pool = try makePool(width: 400, height: 300)

        XCTAssertNotNil(
            compositor.composite(
                screenPixelBuffer: screen,
                screenPresentationTime: time(1.1),
                destinationPool: pool
            )
        )
        provider.setFrame(nil)
        XCTAssertNotNil(
            compositor.composite(
                screenPixelBuffer: screen,
                screenPresentationTime: time(2),
                destinationPool: pool
            )
        )
        XCTAssertTrue(events.snapshot().isEmpty)
        XCTAssertNil(
            compositor.composite(
                screenPixelBuffer: screen,
                screenPresentationTime: time(2.01),
                destinationPool: pool
            )
        )
        XCTAssertEqual(events.snapshot(), [.cameraUnavailable])

        provider.setFrame(try makeFrame(pixelBuffer: camera, time: 2.05, generation: 2))
        XCTAssertNotNil(
            compositor.composite(
                screenPixelBuffer: screen,
                screenPresentationTime: time(2.1),
                destinationPool: pool
            )
        )
        XCTAssertEqual(events.snapshot(), [.cameraUnavailable, .cameraRecovered])
    }

    func testInitialMissingCameraUsesOneSecondGraceBeforeWarning() throws {
        let events = FacecamEventRecorder()
        let compositor = FacecamVideoCompositor(
            cameraFrameProvider: CameraFrameProviderStub(frame: nil),
            placementStore: FacecamPlacementStore(),
            displayGeometry: SelectedDisplayCaptureGeometry(
                displayID: 1,
                frameInScreenPoints: CGRect(x: 0, y: 0, width: 400, height: 300),
                pointPixelScale: 1
            ),
            outputPixelSize: CapturePixelSize(width: 400, height: 300),
            context: CIContext(options: [.useSoftwareRenderer: true]),
            onEvent: { event in events.record(event) }
        )
        let screen = try makePixelBuffer(width: 400, height: 300) { _, _ in .blue }
        let pool = try makePool(width: 400, height: 300)

        XCTAssertNil(
            compositor.composite(
                screenPixelBuffer: screen,
                screenPresentationTime: time(1),
                destinationPool: pool
            )
        )
        XCTAssertNil(
            compositor.composite(
                screenPixelBuffer: screen,
                screenPresentationTime: time(2),
                destinationPool: pool
            )
        )
        XCTAssertTrue(events.snapshot().isEmpty)
        XCTAssertNil(
            compositor.composite(
                screenPixelBuffer: screen,
                screenPresentationTime: time(2.01),
                destinationPool: pool
            )
        )
        XCTAssertEqual(events.snapshot(), [.cameraUnavailable])
    }

    private func mappedRect(
        placement: FacecamPlacement,
        outputSize: CapturePixelSize
    ) throws -> CGRect {
        try XCTUnwrap(
            SelectedDisplayOverlayMapper.map(
                placement: placement,
                displayFrameInScreenPoints: CGRect(x: 0, y: 0, width: 400, height: 300),
                pointPixelScale: 1,
                outputPixelSize: outputSize
            )
        ).rect
    }

    private func makeFrame(
        pixelBuffer: CVPixelBuffer,
        time: Double,
        generation: UInt64
    ) throws -> SynchronizedCameraFrame {
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        let presentationTime = self.time(time)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
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
        return SynchronizedCameraFrame(
            sampleBuffer: try XCTUnwrap(sampleBuffer),
            presentationTimeStamp: presentationTime,
            generation: generation
        )
    }

    private func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        XCTAssertEqual(
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                attributes as CFDictionary,
                &pool
            ),
            kCVReturnSuccess
        )
        return try XCTUnwrap(pool)
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        color: (Int, Int) -> PixelColor
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
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
                let value = color(x, y)
                let pixel = baseAddress + y * bytesPerRow + x * 4
                pixel[0] = value.blue
                pixel[1] = value.green
                pixel[2] = value.red
                pixel[3] = 255
            }
        }
        return buffer
    }

    private func color(atX x: Int, y: Int, in buffer: CVPixelBuffer) throws -> PixelColor {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let pixel = baseAddress + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return PixelColor(blue: pixel[0], green: pixel[1], red: pixel[2])
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}

private final class CameraFrameProviderStub: CameraFrameProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: SynchronizedCameraFrame?

    init(frame: SynchronizedCameraFrame?) {
        self.frame = frame
    }

    func latestFrame() -> SynchronizedCameraFrame? {
        lock.withLock { frame }
    }

    func setFrame(_ frame: SynchronizedCameraFrame?) {
        lock.withLock { self.frame = frame }
    }
}

private final class FacecamEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FacecamVideoCompositorEvent] = []

    func record(_ event: FacecamVideoCompositorEvent) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [FacecamVideoCompositorEvent] {
        lock.withLock { events }
    }
}

private struct PixelColor: Equatable {
    let blue: UInt8
    let green: UInt8
    let red: UInt8

    static let blue = PixelColor(blue: 255, green: 0, red: 0)
    static let red = PixelColor(blue: 0, green: 0, red: 255)
    static let green = PixelColor(blue: 0, green: 255, red: 0)
}
