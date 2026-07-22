import AVFoundation
import XCTest
@testable import Koji

@MainActor
final class RecordingCoordinatorFacecamTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RecordingCoordinatorFacecamTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testIntentionalDisableStopsCameraAndSuppressesLateUnavailableWarning() async {
        let context = makeContext()
        await context.cameraAccessController.setFacecamEnabled(true)
        await context.cameraAccessController.setRecordingConsumerActive(true)
        context.coordinator.state = .recording
        context.coordinator.facecamWarningMessage = "Previous camera warning"

        await context.coordinator.setFacecamEnabled(false)

        XCTAssertEqual(context.coordinator.state, .recording)
        XCTAssertNil(context.coordinator.facecamWarningMessage)
        XCTAssertFalse(context.cameraAccessController.isFacecamEnabled)
        XCTAssertFalse(context.preferences.isFacecamEnabled)
        XCTAssertEqual(context.captureService.stopPreviewCount, 1)
        XCTAssertEqual(context.captureService.stopRecordingCount, 1)

        context.coordinator.handleFacecamCompositorEvent(.cameraUnavailable)

        XCTAssertNil(context.coordinator.facecamWarningMessage)
    }

    func testGenuineUnavailableAndRecoveryEventsStillControlWarning() {
        let context = makeContext()
        context.coordinator.state = .recording

        context.coordinator.handleFacecamCompositorEvent(.cameraUnavailable)

        XCTAssertEqual(
            context.coordinator.facecamWarningMessage,
            "Camera unavailable. Screen and audio recording are continuing. Unlock or reconnect the camera, choose another camera, or use Check Again."
        )

        context.coordinator.handleFacecamCompositorEvent(.cameraRecovered)

        XCTAssertNil(context.coordinator.facecamWarningMessage)
    }

    func testReenablingFacecamRestoresGenuineUnavailableWarnings() async {
        let context = makeContext()
        context.coordinator.state = .recording

        await context.coordinator.setFacecamEnabled(false)
        context.coordinator.handleFacecamCompositorEvent(.cameraUnavailable)
        XCTAssertNil(context.coordinator.facecamWarningMessage)

        await context.coordinator.setFacecamEnabled(true)
        context.coordinator.handleFacecamCompositorEvent(.cameraUnavailable)

        XCTAssertNotNil(context.coordinator.facecamWarningMessage)
    }

    private func makeContext() -> FacecamTestContext {
        let preferences = Preferences(defaults: defaults)
        let permissionsState = PermissionsState(
            cameraAuthorizationClient: FacecamCameraAuthorizationStub(),
            microphoneAuthorizationClient: FacecamMicrophoneAuthorizationStub()
        )
        let discovery = FacecamCameraDiscoveryStub()
        let captureService = FacecamCaptureServiceSpy()
        let cameraAccessController = CameraAccessController(
            permissionsState: permissionsState,
            preferences: preferences,
            discovery: discovery,
            captureService: captureService
        )
        let coordinator = RecordingCoordinator(
            recordingState: RecordingState(),
            permissionsState: permissionsState,
            preferences: preferences,
            notificationManager: NotificationManager(),
            microphoneDiscovery: FacecamMicrophoneDiscoveryStub(),
            cameraAccessController: cameraAccessController
        )

        return FacecamTestContext(
            coordinator: coordinator,
            cameraAccessController: cameraAccessController,
            captureService: captureService,
            preferences: preferences
        )
    }
}

@MainActor
private struct FacecamTestContext {
    let coordinator: RecordingCoordinator
    let cameraAccessController: CameraAccessController
    let captureService: FacecamCaptureServiceSpy
    let preferences: Preferences
}

private final class FacecamCameraAuthorizationStub: CameraAuthorizationClient {
    func authorizationStatus() -> AVAuthorizationStatus {
        .authorized
    }

    func requestAccess() async -> Bool {
        true
    }
}

private final class FacecamMicrophoneAuthorizationStub: MicrophoneAuthorizationClient {
    func authorizationStatus() -> AVAuthorizationStatus {
        .authorized
    }

    func requestAccess() async -> Bool {
        true
    }
}

@MainActor
private final class FacecamCameraDiscoveryStub: CameraDeviceDiscovery {
    private let camera = CameraOption(
        id: "test-camera",
        name: "Test Camera",
        kind: .external
    )

    func currentSnapshot() -> CameraDiscoverySnapshot {
        CameraDiscoverySnapshot(
            cameras: [camera],
            systemPreferredCameraID: camera.id
        )
    }

    func setUserPreferredCamera(deviceID: String) {}
    func startMonitoring(_ onChange: @escaping @MainActor () -> Void) {}
    func stopMonitoring() {}
}

private final class FacecamCaptureServiceSpy: CameraCaptureServicing, @unchecked Sendable {
    let previewSession = AVCaptureSession()
    private(set) var stopPreviewCount = 0
    private(set) var stopRecordingCount = 0

    func startPreview(deviceID: String) async throws -> CameraCaptureFormat {
        format(deviceID: deviceID)
    }

    func stopPreview() async {
        stopPreviewCount += 1
    }

    func startRecording(deviceID: String) async throws -> CameraCaptureFormat {
        format(deviceID: deviceID)
    }

    func stopRecording() async {
        stopRecordingCount += 1
    }

    func latestFrame() -> SynchronizedCameraFrame? {
        nil
    }

    func frameMetrics() -> LatestValueMailboxMetrics {
        LatestValueMailboxMetrics(
            acceptedCount: 0,
            replacementCount: 0,
            currentCount: 0,
            peakCount: 0
        )
    }

    func setEventHandler(_ handler: (@Sendable (CameraCaptureEvent) -> Void)?) {}

    private func format(deviceID: String) -> CameraCaptureFormat {
        CameraCaptureFormat(
            deviceID: deviceID,
            width: 1_920,
            height: 1_080,
            frameRate: 30
        )
    }
}

@MainActor
private final class FacecamMicrophoneDiscoveryStub: MicrophoneDeviceDiscovery {
    func currentSnapshot() throws -> MicrophoneDiscoverySnapshot {
        MicrophoneDiscoverySnapshot(microphones: [], defaultMicrophoneID: nil)
    }

    func startMonitoring(_ onChange: @escaping @MainActor () -> Void) {}
    func stopMonitoring() {}
}
