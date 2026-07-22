import ScreenCaptureKit
import XCTest
@testable import Koji

final class CaptureSampleDiagnosticsTests: XCTestCase {
    func testOnlyCompleteReadyImageFrameIsUsable() {
        XCTAssertEqual(
            ScreenCaptureSampleClassifier.classify(
                isValid: true,
                isDataReady: true,
                hasImageBuffer: true,
                statusRawValue: SCFrameStatus.complete.rawValue
            ),
            .usable
        )
        XCTAssertEqual(
            ScreenCaptureSampleClassifier.classify(
                isValid: true,
                isDataReady: true,
                hasImageBuffer: true,
                statusRawValue: SCFrameStatus.idle.rawValue
            ),
            .nonComplete(.idle)
        )
    }

    func testInvalidReadinessImageAndStatusFailuresAreClassified() {
        XCTAssertEqual(
            ScreenCaptureSampleClassifier.classify(
                isValid: false,
                isDataReady: true,
                hasImageBuffer: true,
                statusRawValue: SCFrameStatus.complete.rawValue
            ),
            .invalid
        )
        XCTAssertEqual(
            ScreenCaptureSampleClassifier.classify(
                isValid: true,
                isDataReady: false,
                hasImageBuffer: true,
                statusRawValue: SCFrameStatus.complete.rawValue
            ),
            .dataNotReady
        )
        XCTAssertEqual(
            ScreenCaptureSampleClassifier.classify(
                isValid: true,
                isDataReady: true,
                hasImageBuffer: false,
                statusRawValue: SCFrameStatus.complete.rawValue
            ),
            .missingImageBuffer
        )
        XCTAssertEqual(
            ScreenCaptureSampleClassifier.classify(
                isValid: true,
                isDataReady: true,
                hasImageBuffer: true,
                statusRawValue: nil
            ),
            .missingFrameStatus
        )
        XCTAssertEqual(
            ScreenCaptureSampleClassifier.classify(
                isValid: true,
                isDataReady: true,
                hasImageBuffer: true,
                statusRawValue: 999
            ),
            .unknownFrameStatus
        )
    }

    func testDiagnosticsKeepOnlyAggregateCountsAndReset() {
        let diagnostics = CaptureSampleDiagnostics()

        diagnostics.recordScreen(.usable)
        diagnostics.recordScreen(.nonComplete(.idle))
        diagnostics.recordScreen(.missingFrameStatus)
        diagnostics.recordSystemAudio()
        diagnostics.recordMicrophone()

        XCTAssertEqual(
            diagnostics.snapshot(),
            CaptureSampleMetrics(
                screenCallbackCount: 3,
                forwardedScreenFrameCount: 1,
                missingFrameStatusCount: 1,
                idleScreenFrameCount: 1,
                systemAudioCallbackCount: 1,
                microphoneCallbackCount: 1
            )
        )

        diagnostics.reset()
        XCTAssertEqual(diagnostics.snapshot(), CaptureSampleMetrics())
    }
}
