import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal

protocol CameraFrameProviding: AnyObject, Sendable {
    func latestFrame() -> SynchronizedCameraFrame?
    func frameMetrics() -> LatestValueMailboxMetrics
}

extension CameraFrameProviding {
    func frameMetrics() -> LatestValueMailboxMetrics {
        LatestValueMailboxMetrics(
            acceptedCount: 0,
            replacementCount: 0,
            currentCount: 0,
            peakCount: 0
        )
    }
}

protocol RecordingVideoCompositing: AnyObject, Sendable {
    func composite(
        screenPixelBuffer: CVPixelBuffer,
        screenPresentationTime: CMTime,
        destinationPool: CVPixelBufferPool
    ) -> CVPixelBuffer?
}

enum FacecamVideoCompositorEvent: Equatable, Sendable {
    case cameraUnavailable
    case cameraRecovered
}

struct FacecamVideoCompositorMetrics: Equatable, Sendable {
    var composedFrameCount = 0
    var screenOnlyFrameCount = 0
    var destinationAllocationFailureCount = 0
    var renderFailureCount = 0
}

struct FacecamVideoCompositorDiagnostics: Equatable, Sendable {
    let composition: FacecamVideoCompositorMetrics
    let synchronization: CameraFrameSynchronizationMetrics
}

final class FacecamVideoCompositor: RecordingVideoCompositing, @unchecked Sendable {
    private enum CameraAvailability {
        case waiting
        case available
        case unavailable
    }

    static let maximumLastFrameDuration = CMTime(seconds: 1, preferredTimescale: 600)

    private let cameraFrameProvider: any CameraFrameProviding
    private let placementStore: FacecamPlacementStore
    private let displayGeometry: SelectedDisplayCaptureGeometry
    private let outputPixelSize: CapturePixelSize
    private let frameSynchronizer: CameraFrameSynchronizer
    private let context: CIContext
    private let onEvent: (@Sendable (FacecamVideoCompositorEvent) -> Void)?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let metricsLock = NSLock()
    private var storedMetrics = FacecamVideoCompositorMetrics()
    private let availabilityLock = NSLock()
    private var cameraAvailability = CameraAvailability.waiting
    private var firstScreenPresentationTime: CMTime?

    init(
        cameraFrameProvider: any CameraFrameProviding,
        placementStore: FacecamPlacementStore,
        displayGeometry: SelectedDisplayCaptureGeometry,
        outputPixelSize: CapturePixelSize,
        frameSynchronizer: CameraFrameSynchronizer = CameraFrameSynchronizer(),
        context: CIContext? = nil,
        onEvent: (@Sendable (FacecamVideoCompositorEvent) -> Void)? = nil
    ) {
        self.cameraFrameProvider = cameraFrameProvider
        self.placementStore = placementStore
        self.displayGeometry = displayGeometry
        self.outputPixelSize = outputPixelSize
        self.frameSynchronizer = frameSynchronizer
        self.context = context ?? Self.makeContext()
        self.onEvent = onEvent
    }

    func composite(
        screenPixelBuffer: CVPixelBuffer,
        screenPresentationTime: CMTime,
        destinationPool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        let cameraFrame = frameSynchronizer.selectFrame(
            latestCameraFrame: cameraFrameProvider.latestFrame(),
            forScreenTime: screenPresentationTime,
            maximumFrameAge: Self.maximumLastFrameDuration
        )
        updateCameraAvailability(
            hasCameraFrame: cameraFrame != nil,
            screenPresentationTime: screenPresentationTime
        )

        guard
            let cameraFrame,
            let cameraPixelBuffer = CMSampleBufferGetImageBuffer(cameraFrame.sampleBuffer),
            let mapping = SelectedDisplayOverlayMapper.map(
                placement: placementStore.snapshot(),
                displayFrameInScreenPoints: displayGeometry.frameInScreenPoints,
                pointPixelScale: displayGeometry.pointPixelScale,
                outputPixelSize: outputPixelSize
            ),
            !mapping.rect.isEmpty
        else {
            record { $0.screenOnlyFrameCount += 1 }
            return nil
        }

        var destination: CVPixelBuffer?
        let allocationAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey as String: 3,
        ] as CFDictionary
        let allocationStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            destinationPool,
            allocationAttributes,
            &destination
        )
        guard allocationStatus == kCVReturnSuccess, let destination else {
            record { $0.destinationAllocationFailureCount += 1 }
            return nil
        }

        let outputBounds = CGRect(
            x: 0,
            y: 0,
            width: outputPixelSize.width,
            height: outputPixelSize.height
        )
        guard
            CVPixelBufferGetWidth(screenPixelBuffer) == outputPixelSize.width,
            CVPixelBufferGetHeight(screenPixelBuffer) == outputPixelSize.height
        else {
            record { $0.renderFailureCount += 1 }
            return nil
        }

        let targetRect = CGRect(
            x: mapping.rect.minX,
            y: outputBounds.height - mapping.rect.maxY,
            width: mapping.rect.width,
            height: mapping.rect.height
        ).intersection(outputBounds)
        guard !targetRect.isEmpty else {
            record { $0.renderFailureCount += 1 }
            return nil
        }

        let screenImage = CIImage(cvPixelBuffer: screenPixelBuffer).cropped(to: outputBounds)
        let cameraImage = CIImage(cvPixelBuffer: cameraPixelBuffer)
            .oriented(Self.orientation(for: cameraFrame.sampleBuffer))
        guard !cameraImage.extent.isEmpty else {
            record { $0.renderFailureCount += 1 }
            return nil
        }

        let placedCamera = Self.aspectFill(cameraImage, into: targetRect)
        let radius = max(8, min(targetRect.width, targetRect.height) * 0.08)
        guard
            let mask = CIFilter(
                name: "CIRoundedRectangleGenerator",
                parameters: [
                    kCIInputExtentKey: CIVector(cgRect: targetRect),
                    "inputRadius": radius,
                    "inputColor": CIColor.white,
                ]
            )?.outputImage?.cropped(to: outputBounds),
            let composite = CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: placedCamera,
                    kCIInputBackgroundImageKey: screenImage,
                    kCIInputMaskImageKey: mask,
                ]
            )?.outputImage?.cropped(to: outputBounds)
        else {
            record { $0.renderFailureCount += 1 }
            return nil
        }

        context.render(
            composite,
            to: destination,
            bounds: outputBounds,
            colorSpace: colorSpace
        )
        record { $0.composedFrameCount += 1 }
        return destination
    }

    func metrics() -> FacecamVideoCompositorMetrics {
        metricsLock.withLock { storedMetrics }
    }

    func diagnostics() -> FacecamVideoCompositorDiagnostics {
        FacecamVideoCompositorDiagnostics(
            composition: metrics(),
            synchronization: frameSynchronizer.metrics()
        )
    }

    private func record(_ update: (inout FacecamVideoCompositorMetrics) -> Void) {
        metricsLock.withLock { update(&storedMetrics) }
    }

    private func updateCameraAvailability(
        hasCameraFrame: Bool,
        screenPresentationTime: CMTime
    ) {
        let event: FacecamVideoCompositorEvent? = availabilityLock.withLock {
            if hasCameraFrame {
                let recovered = cameraAvailability == .unavailable
                cameraAvailability = .available
                return recovered ? .cameraRecovered : nil
            }

            switch cameraAvailability {
            case .available:
                cameraAvailability = .unavailable
                return .cameraUnavailable

            case .unavailable:
                return nil

            case .waiting:
                guard let firstScreenPresentationTime else {
                    self.firstScreenPresentationTime = screenPresentationTime
                    return nil
                }
                let waitingDuration = CMTimeSubtract(
                    screenPresentationTime,
                    firstScreenPresentationTime
                )
                guard
                    CMTIME_IS_VALID(waitingDuration),
                    CMTIME_IS_NUMERIC(waitingDuration),
                    CMTimeCompare(waitingDuration, Self.maximumLastFrameDuration) > 0
                else {
                    return nil
                }
                cameraAvailability = .unavailable
                return .cameraUnavailable
            }
        }
        if let event {
            onEvent?(event)
        }
    }

    private static func makeContext() -> CIContext {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(
                mtlDevice: device,
                options: [
                    .cacheIntermediates: false,
                    .name: "Koji.FacecamVideoCompositor",
                ]
            )
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }

    private static func aspectFill(_ image: CIImage, into targetRect: CGRect) -> CIImage {
        let normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            )
        )
        let scale = max(
            targetRect.width / normalized.extent.width,
            targetRect.height / normalized.extent.height
        )
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translation = CGAffineTransform(
            translationX: targetRect.midX - scaled.extent.midX,
            y: targetRect.midY - scaled.extent.midY
        )
        return scaled.transformed(by: translation).cropped(to: targetRect)
    }

    private static func orientation(for sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard
            let value = CMGetAttachment(
                sampleBuffer,
                key: kCGImagePropertyOrientation as CFString,
                attachmentModeOut: nil
            ) as? NSNumber,
            let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value)
        else {
            return .up
        }
        return orientation
    }
}
