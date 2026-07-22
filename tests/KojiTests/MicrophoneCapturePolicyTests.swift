import AVFoundation
import XCTest
@testable import Koji

final class MicrophoneCapturePolicyTests: XCTestCase {
    func testCaptureTrackIsOmittedWhenMicrophonePreferenceIsDisabled() {
        XCTAssertFalse(
            MicrophoneCapturePolicy.shouldCaptureMicrophoneTrack(
                isMicrophoneEnabled: false,
                requestedCapture: true
            )
        )
    }

    func testDecisionDisablesMicrophoneAndClearsDeviceWhenMicrophoneIsOff() {
        let decision = MicrophoneCapturePolicy.makeDecision(
            isMicrophoneEnabled: false,
            selectedDeviceID: "built-in-mic",
            permissionStatus: .authorized,
            microphoneCaptureSupported: true
        )

        XCTAssertFalse(decision.capturesMicrophone)
        XCTAssertNil(decision.microphoneCaptureDeviceID)
    }

    func testDecisionEnablesMicrophoneWhenRequirementsAreMet() {
        let decision = MicrophoneCapturePolicy.makeDecision(
            isMicrophoneEnabled: true,
            selectedDeviceID: "built-in-mic",
            permissionStatus: .authorized,
            microphoneCaptureSupported: true
        )

        XCTAssertTrue(decision.capturesMicrophone)
        XCTAssertEqual(decision.microphoneCaptureDeviceID, "built-in-mic")
    }

    func testPermissionRequestIsSkippedWhenMicrophoneIsDisabled() {
        XCTAssertFalse(
            MicrophoneCapturePolicy.shouldRequestPermission(
                isMicrophoneEnabled: false,
                permissionStatus: .notDetermined
            )
        )
    }

    func testPermissionRequestRunsWhenMicrophoneIsEnabledAndStatusIsNotDetermined() {
        XCTAssertTrue(
            MicrophoneCapturePolicy.shouldRequestPermission(
                isMicrophoneEnabled: true,
                permissionStatus: .notDetermined
            )
        )
    }

    func testPermissionNoticeIsHiddenWhenMicrophoneIsDisabled() {
        XCTAssertFalse(
            MicrophoneCapturePolicy.shouldShowPermissionNotice(
                isMicrophoneEnabled: false,
                permissionStatus: .notDetermined
            )
        )
    }

    func testPermissionNoticeIsShownWhenMicrophoneIsEnabledAndPermissionIsMissing() {
        XCTAssertTrue(
            MicrophoneCapturePolicy.shouldShowPermissionNotice(
                isMicrophoneEnabled: true,
                permissionStatus: .denied
            )
        )
    }
}
