import AVFoundation
import Foundation
import XCTest
@testable import Koji

@MainActor
final class RecordingCoordinatorMicrophoneTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RecordingCoordinatorMicrophoneTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEnablingFromDisabledPreferenceRequestsPermissionAndPersists() async {
        let authorization = MicrophoneAuthorizationClientSpy(
            status: .notDetermined,
            requestResult: true
        )
        let (coordinator, preferences) = makeCoordinator(authorization: authorization)

        await coordinator.setMicrophoneEnabled(true)

        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertTrue(coordinator.isMicrophoneEnabled)
        XCTAssertTrue(preferences.micEnabled)
    }

    func testScreenOnlyRecordingCanEnableMicrophoneForNextRecording() async {
        let authorization = MicrophoneAuthorizationClientSpy(status: .authorized)
        let (coordinator, preferences) = makeCoordinator(authorization: authorization)
        coordinator.state = .recording
        coordinator.isMicrophoneCaptureActive = false

        XCTAssertTrue(coordinator.canToggleMicrophone)

        await coordinator.setMicrophoneEnabled(true)

        XCTAssertTrue(coordinator.isMicrophoneEnabled)
        XCTAssertTrue(preferences.micEnabled)
        XCTAssertFalse(coordinator.isMicrophoneCaptureActive)
    }

    func testDeniedPermissionPreservesPreferenceAndShowsRecoveryGuidance() async {
        let authorization = MicrophoneAuthorizationClientSpy(
            status: .notDetermined,
            requestResult: false
        )
        let (coordinator, preferences) = makeCoordinator(authorization: authorization)

        await coordinator.setMicrophoneEnabled(true)

        XCTAssertTrue(coordinator.isMicrophoneEnabled)
        XCTAssertTrue(preferences.micEnabled)
        XCTAssertEqual(coordinator.microphoneAuthorizationStatus, .denied)
        XCTAssertNotNil(coordinator.warningMessage)
    }

    func testRecordingWithMicrophoneTrackRetainsLiveMuteAndUnmute() async {
        let authorization = MicrophoneAuthorizationClientSpy(status: .authorized)
        let (coordinator, preferences) = makeCoordinator(
            authorization: authorization,
            isMicrophoneEnabled: true
        )
        coordinator.state = .recording
        coordinator.isMicrophoneCaptureActive = true

        await coordinator.setMicrophoneEnabled(false)
        XCTAssertFalse(coordinator.isMicrophoneEnabled)
        XCTAssertFalse(preferences.micEnabled)

        await coordinator.setMicrophoneEnabled(true)
        XCTAssertTrue(coordinator.isMicrophoneEnabled)
        XCTAssertTrue(preferences.micEnabled)
        XCTAssertTrue(coordinator.isMicrophoneCaptureActive)
    }

    func testRefreshMicrophonesPreservesPreferredDevice() async {
        let discovery = MicrophoneDeviceDiscoverySpy(
            snapshot: MicrophoneDiscoverySnapshot(
                microphones: [
                    MicrophoneOption(id: "built-in-mic", name: "MacBook Pro Microphone"),
                    MicrophoneOption(id: "airpods-mic", name: "AirPods Microphone"),
                ],
                defaultMicrophoneID: "built-in-mic"
            )
        )
        let authorization = MicrophoneAuthorizationClientSpy(status: .authorized)
        let (coordinator, preferences) = makeCoordinator(
            authorization: authorization,
            selectedMicrophoneID: "airpods-mic",
            isMicrophoneEnabled: true,
            discovery: discovery
        )

        await coordinator.refreshMicrophones()

        XCTAssertEqual(
            coordinator.microphoneOptions,
            [
                .none,
                MicrophoneOption(id: "built-in-mic", name: "MacBook Pro Microphone"),
                MicrophoneOption(id: "airpods-mic", name: "AirPods Microphone"),
            ]
        )
        XCTAssertEqual(coordinator.selectedMicrophoneID, "airpods-mic")
        XCTAssertEqual(preferences.selectedMicDeviceID, "airpods-mic")
    }

    func testRefreshMicrophonesFallsBackToDefaultInputWhenPreferredDeviceDisappears() async {
        let discovery = MicrophoneDeviceDiscoverySpy(
            snapshot: MicrophoneDiscoverySnapshot(
                microphones: [
                    MicrophoneOption(id: "built-in-mic", name: "MacBook Pro Microphone"),
                ],
                defaultMicrophoneID: "built-in-mic"
            )
        )
        let authorization = MicrophoneAuthorizationClientSpy(status: .authorized)
        let (coordinator, preferences) = makeCoordinator(
            authorization: authorization,
            selectedMicrophoneID: "disconnected-mic",
            isMicrophoneEnabled: true,
            discovery: discovery
        )

        await coordinator.refreshMicrophones()

        XCTAssertEqual(coordinator.selectedMicrophoneID, "built-in-mic")
        XCTAssertEqual(preferences.selectedMicDeviceID, "built-in-mic")
        XCTAssertTrue(coordinator.isMicrophoneEnabled)
    }

    func testRefreshMicrophonesDisablesInputWhenNoDeviceIsAvailable() async {
        let discovery = MicrophoneDeviceDiscoverySpy(
            snapshot: MicrophoneDiscoverySnapshot(
                microphones: [],
                defaultMicrophoneID: nil
            )
        )
        let authorization = MicrophoneAuthorizationClientSpy(status: .authorized)
        let (coordinator, preferences) = makeCoordinator(
            authorization: authorization,
            isMicrophoneEnabled: true,
            discovery: discovery
        )

        await coordinator.refreshMicrophones()

        XCTAssertEqual(coordinator.microphoneOptions, [.none])
        XCTAssertEqual(coordinator.selectedMicrophoneID, MicrophoneOption.noneID)
        XCTAssertNil(preferences.selectedMicDeviceID)
        XCTAssertFalse(preferences.micEnabled)
    }

    private func makeCoordinator(
        authorization: MicrophoneAuthorizationClientSpy,
        selectedMicrophoneID: String = "test-microphone",
        isMicrophoneEnabled: Bool = false,
        discovery: MicrophoneDeviceDiscoverySpy? = nil
    ) -> (RecordingCoordinator, Preferences) {
        let preferences = Preferences(defaults: defaults)
        preferences.selectedMicDeviceID = selectedMicrophoneID
        preferences.micEnabled = isMicrophoneEnabled

        let coordinator = RecordingCoordinator(
            recordingState: RecordingState(),
            permissionsState: PermissionsState(microphoneAuthorizationClient: authorization),
            preferences: preferences,
            notificationManager: NotificationManager(),
            microphoneDiscovery: discovery ?? MicrophoneDeviceDiscoverySpy()
        )

        return (coordinator, preferences)
    }
}

@MainActor
private final class MicrophoneDeviceDiscoverySpy: MicrophoneDeviceDiscovery {
    var snapshot: MicrophoneDiscoverySnapshot
    private(set) var startMonitoringCount = 0
    private(set) var stopMonitoringCount = 0
    private var onChange: (@MainActor () -> Void)?

    init(
        snapshot: MicrophoneDiscoverySnapshot = MicrophoneDiscoverySnapshot(
            microphones: [MicrophoneOption(id: "test-microphone", name: "Test Microphone")],
            defaultMicrophoneID: "test-microphone"
        )
    ) {
        self.snapshot = snapshot
    }

    func currentSnapshot() throws -> MicrophoneDiscoverySnapshot {
        snapshot
    }

    func startMonitoring(_ onChange: @escaping @MainActor () -> Void) {
        startMonitoringCount += 1
        self.onChange = onChange
    }

    func stopMonitoring() {
        stopMonitoringCount += 1
        onChange = nil
    }
}

private final class MicrophoneAuthorizationClientSpy: MicrophoneAuthorizationClient {
    private(set) var requestCount = 0
    private let requestResult: Bool
    private var status: AVAuthorizationStatus

    init(status: AVAuthorizationStatus, requestResult: Bool = true) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus() -> AVAuthorizationStatus {
        status
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        status = requestResult ? .authorized : .denied
        return requestResult
    }
}
