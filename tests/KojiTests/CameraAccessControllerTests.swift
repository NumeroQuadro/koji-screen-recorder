import AVFoundation
import Foundation
import XCTest
@testable import Koji

@MainActor
final class CameraAccessControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CameraAccessControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMissingPreferenceStaysOffAndStartupRestoreDoesNotTouchCamera() async {
        let authorization = CameraAuthorizationClientSpy(status: .notDetermined)
        let discovery = CameraDeviceDiscoverySpy(snapshot: .empty)
        let captureService = CameraCaptureServiceSpy()
        let permissions = PermissionsState(cameraAuthorizationClient: authorization)
        let preferences = Preferences(defaults: defaults)

        let controller = CameraAccessController(
            permissionsState: permissions,
            preferences: preferences,
            discovery: discovery,
            captureService: captureService
        )

        await controller.restorePersistedFacecamState()

        XCTAssertEqual(authorization.authorizationStatusCount, 0)
        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(discovery.snapshotCount, 0)
        XCTAssertEqual(discovery.startMonitoringCount, 0)
        XCTAssertTrue(captureService.previewDeviceIDs.isEmpty)
        XCTAssertFalse(controller.isFacecamEnabled)
        XCTAssertFalse(preferences.isFacecamEnabled)
    }

    func testPersistedOffStateSkipsCameraWorkDuringStartupRestore() async {
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(snapshot: .empty)
        let captureService = CameraCaptureServiceSpy()
        let preferences = Preferences(defaults: defaults)
        preferences.isFacecamEnabled = false
        let controller = CameraAccessController(
            permissionsState: PermissionsState(cameraAuthorizationClient: authorization),
            preferences: preferences,
            discovery: discovery,
            captureService: captureService
        )

        await controller.restorePersistedFacecamState()

        XCTAssertFalse(controller.isFacecamEnabled)
        XCTAssertEqual(authorization.authorizationStatusCount, 0)
        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(discovery.snapshotCount, 0)
        XCTAssertEqual(discovery.startMonitoringCount, 0)
        XCTAssertTrue(captureService.previewDeviceIDs.isEmpty)
    }

    func testPersistedOnStateRestoresAuthorizedCameraPreview() async {
        let camera = CameraOption(id: "iphone", name: "Dmitriy's iPhone", kind: .continuity)
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [camera],
                systemPreferredCameraID: camera.id
            )
        )
        let captureService = CameraCaptureServiceSpy()
        let preferences = Preferences(defaults: defaults)
        preferences.isFacecamEnabled = true
        let controller = CameraAccessController(
            permissionsState: PermissionsState(cameraAuthorizationClient: authorization),
            preferences: preferences,
            discovery: discovery,
            captureService: captureService
        )

        XCTAssertFalse(controller.isFacecamEnabled)
        XCTAssertEqual(authorization.authorizationStatusCount, 0)
        XCTAssertEqual(discovery.snapshotCount, 0)

        await controller.restorePersistedFacecamState()

        XCTAssertTrue(controller.isFacecamEnabled)
        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(discovery.snapshotCount, 1)
        XCTAssertEqual(discovery.startMonitoringCount, 1)
        XCTAssertEqual(controller.selectedCameraID, camera.id)
        XCTAssertEqual(captureService.previewDeviceIDs, [camera.id])
    }

    func testGeneralPermissionRefreshDoesNotTouchCameraAuthorization() async {
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let permissions = PermissionsState(cameraAuthorizationClient: authorization)

        await permissions.refresh()

        XCTAssertEqual(authorization.authorizationStatusCount, 0)
        XCTAssertEqual(permissions.camera, .notDetermined)
    }

    func testExplicitEnableRequestsUndeterminedPermissionOnceAndDiscoversCameras() async {
        let camera = CameraOption(id: "iphone", name: "Dmitriy's iPhone", kind: .continuity)
        let authorization = CameraAuthorizationClientSpy(status: .notDetermined, requestResult: true)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [camera],
                systemPreferredCameraID: camera.id
            )
        )
        let captureService = CameraCaptureServiceSpy()
        let controller = makeController(
            authorization: authorization,
            discovery: discovery,
            captureService: captureService
        )

        await controller.setFacecamEnabled(true)
        await controller.setFacecamEnabled(true)

        XCTAssertGreaterThan(authorization.authorizationStatusCount, 0)
        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(discovery.snapshotCount, 1)
        XCTAssertEqual(discovery.startMonitoringCount, 1)
        XCTAssertEqual(controller.accessState, .authorized)
        XCTAssertEqual(controller.selectedCameraID, camera.id)
        XCTAssertTrue(controller.canUseFacecam)
        XCTAssertEqual(captureService.previewDeviceIDs, [camera.id])
        XCTAssertEqual(controller.captureState, .previewing)
        XCTAssertTrue(Preferences(defaults: defaults).isFacecamEnabled)
    }

    func testDeniedAuthorizationDoesNotDiscoverAndKeepsScreenOnlyPathAvailable() async {
        let authorization = CameraAuthorizationClientSpy(status: .notDetermined, requestResult: false)
        let discovery = CameraDeviceDiscoverySpy(snapshot: .empty)
        let controller = makeController(authorization: authorization, discovery: discovery)

        await controller.setFacecamEnabled(true)

        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(discovery.snapshotCount, 0)
        XCTAssertEqual(controller.accessState, .denied)
        XCTAssertNil(controller.selectedCameraID)
        XCTAssertFalse(controller.canUseFacecam)
    }

    func testRestrictedAuthorizationDoesNotRequestOrDiscoverCameras() async {
        let authorization = CameraAuthorizationClientSpy(status: .restricted)
        let discovery = CameraDeviceDiscoverySpy(snapshot: .empty)
        let controller = makeController(authorization: authorization, discovery: discovery)

        await controller.setFacecamEnabled(true)

        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(discovery.snapshotCount, 0)
        XCTAssertEqual(controller.accessState, .restricted)
        XCTAssertFalse(controller.canUseFacecam)
    }

    func testAuthorizedEmptyDiscoveryBecomesAvailableWhenCameraConnects() async {
        let camera = CameraOption(id: "iphone", name: "Dmitriy's iPhone", kind: .continuity)
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(snapshot: .empty)
        let controller = makeController(authorization: authorization, discovery: discovery)

        await controller.setFacecamEnabled(true)

        XCTAssertEqual(controller.accessState, .unavailable)
        XCTAssertNil(controller.selectedCameraID)

        discovery.snapshot = CameraDiscoverySnapshot(
            cameras: [camera],
            systemPreferredCameraID: camera.id
        )
        discovery.sendChange()
        await settleAsyncWork()

        XCTAssertEqual(controller.accessState, .authorized)
        XCTAssertEqual(controller.selectedCameraID, camera.id)
    }

    func testAutomaticSelectionTracksSystemPreferenceAndFallsBackToAvailableCamera() async {
        let external = CameraOption(id: "usb", name: "Studio Camera", kind: .external)
        let continuity = CameraOption(id: "iphone", name: "Dmitriy's iPhone", kind: .continuity)
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [external, continuity],
                systemPreferredCameraID: continuity.id
            )
        )
        let controller = makeController(authorization: authorization, discovery: discovery)

        await controller.setFacecamEnabled(true)
        XCTAssertEqual(controller.selectedCameraID, continuity.id)

        discovery.snapshot = CameraDiscoverySnapshot(
            cameras: [external, continuity],
            systemPreferredCameraID: nil
        )
        discovery.sendChange()
        await settleAsyncWork()

        XCTAssertEqual(controller.selection, .automatic)
        XCTAssertEqual(controller.selectedCameraID, external.id)
        XCTAssertEqual(controller.accessState, .authorized)
    }

    func testManualSelectionStaysManualWhileDisconnectedAndRecoversWhenDeviceReturns() async {
        let external = CameraOption(id: "usb", name: "Studio Camera", kind: .external)
        let continuity = CameraOption(id: "iphone", name: "Dmitriy's iPhone", kind: .continuity)
        let preferences = Preferences(defaults: defaults)
        preferences.cameraSelection = .manual(deviceID: continuity.id)

        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [external],
                systemPreferredCameraID: external.id
            )
        )
        let permissions = PermissionsState(cameraAuthorizationClient: authorization)
        let controller = CameraAccessController(
            permissionsState: permissions,
            preferences: preferences,
            discovery: discovery,
            captureService: CameraCaptureServiceSpy()
        )

        await controller.setFacecamEnabled(true)

        XCTAssertEqual(controller.selection, .manual(deviceID: continuity.id))
        XCTAssertEqual(controller.accessState, .disconnected)
        XCTAssertNil(controller.selectedCameraID)

        discovery.snapshot = CameraDiscoverySnapshot(
            cameras: [external, continuity],
            systemPreferredCameraID: external.id
        )
        discovery.sendChange()
        await settleAsyncWork()

        XCTAssertEqual(controller.selection, .manual(deviceID: continuity.id))
        XCTAssertEqual(controller.selectedCameraID, continuity.id)
        XCTAssertEqual(controller.accessState, .authorized)
    }

    func testManualSelectionUpdatesUserPreferredCameraAndPersists() async {
        let external = CameraOption(id: "usb", name: "Studio Camera", kind: .external)
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [external],
                systemPreferredCameraID: external.id
            )
        )
        let controller = makeController(authorization: authorization, discovery: discovery)
        await controller.setFacecamEnabled(true)

        await controller.selectCamera(.manual(deviceID: external.id))

        XCTAssertEqual(discovery.userPreferredCameraIDs, [external.id])
        XCTAssertEqual(Preferences(defaults: defaults).cameraSelection, .manual(deviceID: external.id))
    }

    func testDisablingFacecamStopsCaptureAndClearsPreviewState() async {
        let camera = CameraOption(id: "iphone", name: "Dmitriy's iPhone", kind: .continuity)
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [camera],
                systemPreferredCameraID: camera.id
            )
        )
        let captureService = CameraCaptureServiceSpy()
        let controller = makeController(
            authorization: authorization,
            discovery: discovery,
            captureService: captureService
        )

        await controller.setFacecamEnabled(true)
        await controller.setFacecamEnabled(false)

        XCTAssertFalse(controller.isFacecamEnabled)
        XCTAssertFalse(controller.canUseFacecam)
        XCTAssertEqual(controller.captureState, .inactive)
        XCTAssertNil(controller.negotiatedFormat)
        XCTAssertEqual(captureService.stopPreviewCount, 1)
        XCTAssertEqual(captureService.stopRecordingCount, 1)
        XCTAssertFalse(Preferences(defaults: defaults).isFacecamEnabled)
    }

    func testCaptureStartFailureIsNonfatalAndRetryable() async {
        let camera = CameraOption(id: "busy", name: "Busy Camera", kind: .external)
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [camera],
                systemPreferredCameraID: camera.id
            )
        )
        let captureService = CameraCaptureServiceSpy()
        captureService.previewError = .failedToStart
        let controller = makeController(
            authorization: authorization,
            discovery: discovery,
            captureService: captureService
        )

        await controller.setFacecamEnabled(true)

        XCTAssertTrue(controller.isFacecamEnabled)
        XCTAssertEqual(controller.accessState, .authorized)
        XCTAssertEqual(controller.captureState, .failed(.failedToStart))
        XCTAssertFalse(controller.canUseFacecam)

        captureService.previewError = nil
        await controller.retryCapture()

        XCTAssertEqual(controller.captureState, .previewing)
        XCTAssertTrue(controller.canUseFacecam)
    }

    func testCaptureInterruptionSurfacesErrorAndRetriesWhenInterruptionEnds() async {
        let camera = CameraOption(id: "iphone", name: "Dmitriy's iPhone", kind: .continuity)
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [camera],
                systemPreferredCameraID: camera.id
            )
        )
        let captureService = CameraCaptureServiceSpy()
        let controller = makeController(
            authorization: authorization,
            discovery: discovery,
            captureService: captureService
        )
        await controller.setFacecamEnabled(true)

        captureService.send(.interrupted)
        await waitUntil { controller.captureState == .failed(.interrupted) }
        XCTAssertEqual(controller.captureState, .failed(.interrupted))

        captureService.send(.interruptionEnded)
        await waitUntil { controller.captureState == .previewing }
        XCTAssertEqual(controller.captureState, .previewing)
        XCTAssertEqual(captureService.previewDeviceIDs, [camera.id, camera.id])
    }

    func testRuntimeFailureDuringRecordingIsNonfatalAndRetryRestoresRecordingCapture() async {
        let camera = CameraOption(id: "iphone", name: "Dmitriy's iPhone", kind: .continuity)
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [camera],
                systemPreferredCameraID: camera.id
            )
        )
        let captureService = CameraCaptureServiceSpy()
        let controller = makeController(
            authorization: authorization,
            discovery: discovery,
            captureService: captureService
        )
        await controller.setFacecamEnabled(true)
        await controller.setRecordingConsumerActive(true)

        captureService.send(.runtimeFailure)
        await waitUntil { controller.captureState == .failed(.runtimeFailure) }

        XCTAssertTrue(controller.isFacecamEnabled)
        XCTAssertEqual(controller.captureState, .failed(.runtimeFailure))
        XCTAssertEqual(captureService.stopRecordingCount, 0)

        await controller.retryCapture()

        XCTAssertEqual(controller.captureState, .previewingAndRecording)
        XCTAssertEqual(captureService.recordingDeviceIDs, [camera.id])
    }

    func testCameraCanBeReselectedWhileRecordingWithoutRestartingRecordingConsumer() async {
        let continuity = CameraOption(id: "iphone", name: "Dmitriy's iPhone", kind: .continuity)
        let external = CameraOption(id: "usb", name: "Studio Camera", kind: .external)
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [continuity, external],
                systemPreferredCameraID: continuity.id
            )
        )
        let captureService = CameraCaptureServiceSpy()
        let controller = makeController(
            authorization: authorization,
            discovery: discovery,
            captureService: captureService
        )
        await controller.setFacecamEnabled(true)
        await controller.setRecordingConsumerActive(true)

        await controller.selectCamera(.manual(deviceID: external.id))

        XCTAssertEqual(controller.selectedCameraID, external.id)
        XCTAssertEqual(controller.captureState, .previewingAndRecording)
        XCTAssertEqual(captureService.previewDeviceIDs, [continuity.id, external.id])
        XCTAssertEqual(captureService.recordingDeviceIDs, [continuity.id])
        XCTAssertEqual(captureService.stopRecordingCount, 0)
    }

    func testPermissionRevocationStopsOnlyCameraAndAuthorizedRefreshRestoresFrames() async {
        let camera = CameraOption(id: "iphone", name: "Dmitriy's iPhone", kind: .continuity)
        let authorization = CameraAuthorizationClientSpy(status: .authorized)
        let discovery = CameraDeviceDiscoverySpy(
            snapshot: CameraDiscoverySnapshot(
                cameras: [camera],
                systemPreferredCameraID: camera.id
            )
        )
        let captureService = CameraCaptureServiceSpy()
        let controller = makeController(
            authorization: authorization,
            discovery: discovery,
            captureService: captureService
        )
        await controller.setFacecamEnabled(true)
        await controller.setRecordingConsumerActive(true)

        authorization.status = .denied
        await controller.refreshAfterSystemSettingsChange()

        XCTAssertTrue(controller.isFacecamEnabled)
        XCTAssertEqual(controller.accessState, .denied)
        XCTAssertEqual(controller.captureState, .inactive)
        XCTAssertGreaterThanOrEqual(captureService.stopPreviewCount, 1)
        XCTAssertGreaterThanOrEqual(captureService.stopRecordingCount, 1)

        authorization.status = .authorized
        await controller.refreshAfterSystemSettingsChange()

        XCTAssertEqual(controller.accessState, .authorized)
        XCTAssertEqual(controller.selectedCameraID, camera.id)
        XCTAssertEqual(controller.captureState, .previewing)
        XCTAssertTrue(controller.canUseFacecam)
    }

    func testAuthorizationPolicyRequiresAnExplicitFacecamAction() {
        XCTAssertFalse(
            CameraAuthorizationPolicy.shouldRequestPermission(
                isFacecamAction: false,
                permissionStatus: .notDetermined
            )
        )
        XCTAssertTrue(
            CameraAuthorizationPolicy.shouldRequestPermission(
                isFacecamAction: true,
                permissionStatus: .notDetermined
            )
        )
        XCTAssertFalse(
            CameraAuthorizationPolicy.shouldRequestPermission(
                isFacecamAction: true,
                permissionStatus: .denied
            )
        )
    }

    private func makeController(
        authorization: CameraAuthorizationClientSpy,
        discovery: CameraDeviceDiscoverySpy,
        captureService: CameraCaptureServiceSpy = CameraCaptureServiceSpy()
    ) -> CameraAccessController {
        CameraAccessController(
            permissionsState: PermissionsState(cameraAuthorizationClient: authorization),
            preferences: Preferences(defaults: defaults),
            discovery: discovery,
            captureService: captureService
        )
    }

    private func settleAsyncWork() async {
        await Task.yield()
        await Task.yield()
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class CameraAuthorizationClientSpy: CameraAuthorizationClient {
    private(set) var authorizationStatusCount = 0
    private(set) var requestCount = 0
    private let requestResult: Bool
    var status: AVAuthorizationStatus

    init(status: AVAuthorizationStatus, requestResult: Bool = true) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus() -> AVAuthorizationStatus {
        authorizationStatusCount += 1
        return status
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        status = requestResult ? .authorized : .denied
        return requestResult
    }
}

private final class CameraCaptureServiceSpy: CameraCaptureServicing, @unchecked Sendable {
    let previewSession = AVCaptureSession()
    private(set) var previewDeviceIDs: [String] = []
    private(set) var recordingDeviceIDs: [String] = []
    private(set) var stopPreviewCount = 0
    private(set) var stopRecordingCount = 0
    var previewError: CameraCaptureError?
    private var eventHandler: (@Sendable (CameraCaptureEvent) -> Void)?

    func startPreview(deviceID: String) async throws -> CameraCaptureFormat {
        previewDeviceIDs.append(deviceID)
        if let previewError {
            throw previewError
        }
        return format(deviceID: deviceID)
    }

    func stopPreview() async {
        stopPreviewCount += 1
    }

    func startRecording(deviceID: String) async throws -> CameraCaptureFormat {
        recordingDeviceIDs.append(deviceID)
        return format(deviceID: deviceID)
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

    func setEventHandler(_ handler: (@Sendable (CameraCaptureEvent) -> Void)?) {
        eventHandler = handler
    }

    func send(_ event: CameraCaptureEvent) {
        eventHandler?(event)
    }

    private func format(deviceID: String) -> CameraCaptureFormat {
        CameraCaptureFormat(deviceID: deviceID, width: 1_920, height: 1_080, frameRate: 30)
    }
}

@MainActor
private final class CameraDeviceDiscoverySpy: CameraDeviceDiscovery {
    var snapshot: CameraDiscoverySnapshot
    private(set) var snapshotCount = 0
    private(set) var startMonitoringCount = 0
    private(set) var stopMonitoringCount = 0
    private(set) var userPreferredCameraIDs: [String] = []
    private var onChange: (@MainActor () -> Void)?

    init(snapshot: CameraDiscoverySnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> CameraDiscoverySnapshot {
        snapshotCount += 1
        return snapshot
    }

    func setUserPreferredCamera(deviceID: String) {
        userPreferredCameraIDs.append(deviceID)
    }

    func startMonitoring(_ onChange: @escaping @MainActor () -> Void) {
        startMonitoringCount += 1
        self.onChange = onChange
    }

    func stopMonitoring() {
        stopMonitoringCount += 1
        onChange = nil
    }

    func sendChange() {
        onChange?()
    }
}

private extension CameraDiscoverySnapshot {
    static let empty = CameraDiscoverySnapshot(cameras: [], systemPreferredCameraID: nil)
}
