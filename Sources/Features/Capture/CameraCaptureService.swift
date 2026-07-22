import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

struct CameraCaptureFormat: Equatable, Sendable {
    let deviceID: String
    let width: Int
    let height: Int
    let frameRate: Double
}

struct SynchronizedCameraFrame: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    /// Presentation time converted from the AVCaptureSession synchronization clock to host time.
    let presentationTimeStamp: CMTime
    /// Increments whenever the real capture backend successfully configures a new session input.
    let generation: UInt64
}

protocol CameraTimestampConverting: Sendable {
    func convertToHostTime(_ time: CMTime, from sourceClock: CMClock) -> CMTime?
}

struct CoreMediaCameraTimestampConverter: CameraTimestampConverting {
    func convertToHostTime(_ time: CMTime, from sourceClock: CMClock) -> CMTime? {
        guard CMTIME_IS_VALID(time), CMTIME_IS_NUMERIC(time) else { return nil }
        let converted = CMSyncConvertTime(
            time,
            from: sourceClock,
            to: CMClockGetHostTimeClock()
        )
        guard CMTIME_IS_VALID(converted), CMTIME_IS_NUMERIC(converted) else { return nil }
        return converted
    }
}

struct CameraFormatCandidate: Equatable, Sendable {
    let formatIndex: Int
    let width: Int
    let height: Int
    let minimumFrameRate: Double
    let maximumFrameRate: Double
}

struct CameraFormatSelection: Equatable, Sendable {
    let formatIndex: Int
    let width: Int
    let height: Int
    let frameRate: Double
}

enum CameraCaptureError: LocalizedError, Equatable, Sendable {
    case deviceUnavailable
    case unsupportedFormat
    case cannotCreateInput
    case cannotAddInput
    case cannotAddOutput
    case failedToStart
    case interrupted
    case runtimeFailure

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            "The selected camera is unavailable. Unlock or reconnect it, then choose Check Again."
        case .unsupportedFormat:
            "The selected camera does not provide a supported format up to 1080p at 30 fps."
        case .cannotCreateInput, .cannotAddInput, .cannotAddOutput:
            "Koji could not configure this camera. It may be busy in another app; close that app and try again."
        case .failedToStart:
            "The camera did not start. Unlock or reconnect it, or close another app using it, then try again."
        case .interrupted:
            "The camera preview was interrupted. Unlock or reconnect the camera, then choose Check Again."
        case .runtimeFailure:
            "The camera stopped unexpectedly. Screen and audio recording remain available; choose Check Again to retry."
        }
    }
}

enum CameraCaptureEvent: Equatable, Sendable {
    case interrupted
    case interruptionEnded
    case runtimeFailure
}

enum CameraCaptureState: Equatable, Sendable {
    case inactive
    case starting
    case previewing
    case recording
    case previewingAndRecording
    case failed(CameraCaptureError)

    var isProvidingFrames: Bool {
        switch self {
        case .previewing, .recording, .previewingAndRecording:
            true
        case .inactive, .starting, .failed:
            false
        }
    }
}

enum CameraFormatSelector {
    static let maximumLongEdge = 1_920
    static let maximumShortEdge = 1_080
    static let maximumFrameRate = 30.0

    static func select(from candidates: [CameraFormatCandidate]) -> CameraFormatSelection? {
        candidates.compactMap { candidate -> CameraFormatSelection? in
            let longEdge = max(candidate.width, candidate.height)
            let shortEdge = min(candidate.width, candidate.height)
            guard
                candidate.width > 0,
                candidate.height > 0,
                longEdge <= maximumLongEdge,
                shortEdge <= maximumShortEdge,
                candidate.minimumFrameRate <= maximumFrameRate,
                candidate.maximumFrameRate > 0
            else {
                return nil
            }

            let frameRate = min(maximumFrameRate, candidate.maximumFrameRate)
            guard frameRate >= candidate.minimumFrameRate else { return nil }
            return CameraFormatSelection(
                formatIndex: candidate.formatIndex,
                width: candidate.width,
                height: candidate.height,
                frameRate: frameRate
            )
        }
        .max { lhs, rhs in
            let lhsArea = lhs.width * lhs.height
            let rhsArea = rhs.width * rhs.height
            if lhsArea != rhsArea {
                return lhsArea < rhsArea
            }
            if lhs.frameRate != rhs.frameRate {
                return lhs.frameRate < rhs.frameRate
            }
            return lhs.formatIndex > rhs.formatIndex
        }
    }
}

protocol CameraCaptureServicing: AnyObject, Sendable {
    var previewSession: AVCaptureSession { get }

    func startPreview(deviceID: String) async throws -> CameraCaptureFormat
    func stopPreview() async
    func startRecording(deviceID: String) async throws -> CameraCaptureFormat
    func stopRecording() async
    func latestFrame() -> SynchronizedCameraFrame?
    func frameMetrics() -> LatestValueMailboxMetrics
    func setEventHandler(_ handler: (@Sendable (CameraCaptureEvent) -> Void)?)
}

protocol CameraCaptureBackend: AnyObject {
    var previewSession: AVCaptureSession { get }
    var isRunning: Bool { get }
    var synchronizationClock: CMClock? { get }
    var frameGeneration: UInt64 { get }

    func configure(deviceID: String) throws -> CameraCaptureFormat
    func startRunning() throws
    func stopRunning()
    func tearDown()
}

final class CameraCaptureService: CameraCaptureServicing, CameraFrameProviding, @unchecked Sendable {
    private enum Consumer {
        case preview
        case recording
    }

    private let queue = DispatchQueue(label: "Koji.CameraCaptureService")
    private let backend: any CameraCaptureBackend
    private let mailbox: LatestValueMailbox<CMSampleBuffer>
    private let timestampConverter: any CameraTimestampConverting
    private let eventLock = NSLock()
    private var eventHandler: (@Sendable (CameraCaptureEvent) -> Void)?
    private var notificationObservers: [NSObjectProtocol] = []

    private var previewRequested = false
    private var recordingRequested = false
    private var activeDeviceID: String?
    private var negotiatedFormat: CameraCaptureFormat?

    var previewSession: AVCaptureSession {
        backend.previewSession
    }

    convenience init() {
        let mailbox = LatestValueMailbox<CMSampleBuffer>()
        let backend = AVFoundationCameraCaptureBackend { sampleBuffer in
            mailbox.replace(with: sampleBuffer)
        }
        self.init(backend: backend, mailbox: mailbox)
    }

    init(
        backend: any CameraCaptureBackend,
        mailbox: LatestValueMailbox<CMSampleBuffer> = LatestValueMailbox(),
        timestampConverter: any CameraTimestampConverting = CoreMediaCameraTimestampConverter()
    ) {
        self.backend = backend
        self.mailbox = mailbox
        self.timestampConverter = timestampConverter
        observeSessionEvents()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func startPreview(deviceID: String) async throws -> CameraCaptureFormat {
        try await activate(.preview, deviceID: deviceID)
    }

    func stopPreview() async {
        await deactivate(.preview)
    }

    func startRecording(deviceID: String) async throws -> CameraCaptureFormat {
        try await activate(.recording, deviceID: deviceID)
    }

    func stopRecording() async {
        await deactivate(.recording)
    }

    func latestFrame() -> SynchronizedCameraFrame? {
        guard
            let sampleBuffer = mailbox.latest(),
            let synchronizationClock = backend.synchronizationClock,
            let presentationTimeStamp = timestampConverter.convertToHostTime(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                from: synchronizationClock
            )
        else {
            return nil
        }

        return SynchronizedCameraFrame(
            sampleBuffer: sampleBuffer,
            presentationTimeStamp: presentationTimeStamp,
            generation: backend.frameGeneration
        )
    }

    func frameMetrics() -> LatestValueMailboxMetrics {
        mailbox.metrics()
    }

    func setEventHandler(_ handler: (@Sendable (CameraCaptureEvent) -> Void)?) {
        eventLock.lock()
        eventHandler = handler
        eventLock.unlock()
    }

    private func activate(
        _ consumer: Consumer,
        deviceID: String
    ) async throws -> CameraCaptureFormat {
        try await perform { [self] in
            let previousPreviewRequested = previewRequested
            let previousRecordingRequested = recordingRequested
            setRequested(true, for: consumer)

            do {
                if activeDeviceID != deviceID || negotiatedFormat == nil {
                    negotiatedFormat = try backend.configure(deviceID: deviceID)
                    activeDeviceID = deviceID
                    mailbox.clear()
                }

                if !backend.isRunning {
                    try backend.startRunning()
                }

                guard let negotiatedFormat else {
                    throw CameraCaptureError.failedToStart
                }
                return negotiatedFormat
            } catch {
                previewRequested = previousPreviewRequested
                recordingRequested = previousRecordingRequested
                if !shouldRun {
                    stopAndTearDown()
                }
                throw normalized(error)
            }
        }
    }

    private func deactivate(_ consumer: Consumer) async {
        await perform { [self] in
            setRequested(false, for: consumer)
            if !shouldRun {
                stopAndTearDown()
            }
        }
    }

    private var shouldRun: Bool {
        previewRequested || recordingRequested
    }

    private func setRequested(_ isRequested: Bool, for consumer: Consumer) {
        switch consumer {
        case .preview:
            previewRequested = isRequested
        case .recording:
            recordingRequested = isRequested
        }
    }

    private func stopAndTearDown() {
        if backend.isRunning {
            backend.stopRunning()
        }
        backend.tearDown()
        activeDeviceID = nil
        negotiatedFormat = nil
        mailbox.clear()
    }

    private func normalized(_ error: Error) -> CameraCaptureError {
        error as? CameraCaptureError ?? .failedToStart
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func perform(_ operation: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                operation()
                continuation.resume()
            }
        }
    }

    private func observeSessionEvents() {
        let center = NotificationCenter.default
        let session = backend.previewSession
        notificationObservers = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.publish(.interrupted)
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.publish(.interruptionEnded)
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.publish(.runtimeFailure)
            },
        ]
    }

    private func publish(_ event: CameraCaptureEvent) {
        eventLock.lock()
        let handler = eventHandler
        eventLock.unlock()
        handler?(event)
    }
}

private final class AVFoundationCameraCaptureBackend: NSObject, CameraCaptureBackend, AVCaptureVideoDataOutputSampleBufferDelegate {
    let previewSession = AVCaptureSession()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "Koji.CameraCaptureService.samples")
    private let onFrame: (CMSampleBuffer) -> Void
    private let generationLock = NSLock()
    private var currentInput: AVCaptureDeviceInput?
    private var storedFrameGeneration: UInt64 = 0

    var isRunning: Bool {
        previewSession.isRunning
    }

    var synchronizationClock: CMClock? {
        previewSession.synchronizationClock
    }

    var frameGeneration: UInt64 {
        generationLock.withLock { storedFrameGeneration }
    }

    init(onFrame: @escaping (CMSampleBuffer) -> Void) {
        self.onFrame = onFrame
        super.init()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    func configure(deviceID: String) throws -> CameraCaptureFormat {
        guard let device = resolveDevice(deviceID: deviceID) else {
            throw CameraCaptureError.deviceUnavailable
        }

        let candidates = formatCandidates(for: device)
        guard let selection = CameraFormatSelector.select(from: candidates) else {
            throw CameraCaptureError.unsupportedFormat
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraCaptureError.cannotCreateInput
        }

        previewSession.beginConfiguration()
        defer { previewSession.commitConfiguration() }

        let previousInput = currentInput
        var addedOutput = false
        if let previousInput {
            previewSession.removeInput(previousInput)
        }

        guard previewSession.canAddInput(input) else {
            if let previousInput, previewSession.canAddInput(previousInput) {
                previewSession.addInput(previousInput)
            }
            throw CameraCaptureError.cannotAddInput
        }
        previewSession.addInput(input)

        if !previewSession.outputs.contains(where: { $0 === videoOutput }) {
            guard previewSession.canAddOutput(videoOutput) else {
                previewSession.removeInput(input)
                if let previousInput, previewSession.canAddInput(previousInput) {
                    previewSession.addInput(previousInput)
                }
                throw CameraCaptureError.cannotAddOutput
            }
            previewSession.addOutput(videoOutput)
            addedOutput = true
        }

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            device.activeFormat = device.formats[selection.formatIndex]
            let frameDuration = CMTime(
                seconds: 1.0 / selection.frameRate,
                preferredTimescale: 60_000
            )
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
        } catch {
            previewSession.removeInput(input)
            if addedOutput {
                previewSession.removeOutput(videoOutput)
            }
            if let previousInput, previewSession.canAddInput(previousInput) {
                previewSession.addInput(previousInput)
            }
            throw CameraCaptureError.cannotCreateInput
        }

        currentInput = input
        generationLock.withLock { storedFrameGeneration &+= 1 }
        return CameraCaptureFormat(
            deviceID: deviceID,
            width: selection.width,
            height: selection.height,
            frameRate: selection.frameRate
        )
    }

    func startRunning() throws {
        guard !previewSession.isRunning else { return }
        previewSession.startRunning()
        guard previewSession.isRunning else {
            throw CameraCaptureError.failedToStart
        }
    }

    func stopRunning() {
        guard previewSession.isRunning else { return }
        previewSession.stopRunning()
    }

    func tearDown() {
        previewSession.beginConfiguration()
        if let currentInput {
            previewSession.removeInput(currentInput)
        }
        if previewSession.outputs.contains(where: { $0 === videoOutput }) {
            previewSession.removeOutput(videoOutput)
        }
        previewSession.commitConfiguration()
        currentInput = nil
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onFrame(sampleBuffer)
    }

    private func resolveDevice(deviceID: String) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices.first(where: { $0.uniqueID == deviceID })
    }

    private func formatCandidates(for device: AVCaptureDevice) -> [CameraFormatCandidate] {
        device.formats.enumerated().flatMap { index, format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return format.videoSupportedFrameRateRanges.map { range in
                CameraFormatCandidate(
                    formatIndex: index,
                    width: Int(dimensions.width),
                    height: Int(dimensions.height),
                    minimumFrameRate: range.minFrameRate,
                    maximumFrameRate: range.maxFrameRate
                )
            }
        }
    }
}
