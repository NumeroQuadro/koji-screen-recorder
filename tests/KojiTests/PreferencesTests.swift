import Foundation
import XCTest
@testable import Koji

@MainActor
final class PreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testIncludeMicrophoneInRecordingsPersistsAcrossInstances() {
        let preferences = Preferences(defaults: defaults)
        preferences.selectedMicDeviceID = "built-in-mic"
        preferences.includeMicrophoneInRecordings = false

        let reloadedPreferences = Preferences(defaults: defaults)

        XCTAssertFalse(reloadedPreferences.includeMicrophoneInRecordings)
    }

    func testManualCameraSelectionPersistsAcrossInstances() {
        let preferences = Preferences(defaults: defaults)
        preferences.cameraSelection = .manual(deviceID: "continuity-camera-id")

        let reloadedPreferences = Preferences(defaults: defaults)

        XCTAssertEqual(
            reloadedPreferences.cameraSelection,
            .manual(deviceID: "continuity-camera-id")
        )
    }

    func testFacecamDefaultsOffAndPersistsTheLastToggleState() {
        let preferences = Preferences(defaults: defaults)

        XCTAssertFalse(preferences.isFacecamEnabled)

        preferences.isFacecamEnabled = true
        XCTAssertTrue(Preferences(defaults: defaults).isFacecamEnabled)

        preferences.isFacecamEnabled = false
        XCTAssertFalse(Preferences(defaults: defaults).isFacecamEnabled)
    }

    func testFacecamPlacementPersistsAcrossInstances() {
        let preferences = Preferences(defaults: defaults)
        preferences.facecamPlacement = FacecamPlacement(
            normalizedCenterX: 0.31,
            normalizedCenterY: 0.72,
            sizePreset: .large,
            aspectRatio: 4.0 / 3.0
        )

        let reloadedPreferences = Preferences(defaults: defaults)

        XCTAssertEqual(reloadedPreferences.facecamPlacement, preferences.facecamPlacement)
    }
}
