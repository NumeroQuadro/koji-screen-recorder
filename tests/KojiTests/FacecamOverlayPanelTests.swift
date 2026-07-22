import AVFoundation
import CoreGraphics
import XCTest
@testable import Koji

@MainActor
final class FacecamOverlayPanelTests: XCTestCase {
    func testPanelNeverBecomesKeyOrMainAndUsesNonactivatingStyle() {
        let panel = FacecamOverlayPanel(session: AVCaptureSession())

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    func testUpdateMapsPlacementIntoASecondaryDisplayGlobalFrame() {
        let panel = FacecamOverlayPanel(session: AVCaptureSession())
        let displayFrame = CGRect(x: -1_920, y: 180, width: 1_920, height: 1_080)
        let placement = FacecamPlacement(
            normalizedCenterX: 0.25,
            normalizedCenterY: 0.75,
            sizePreset: .medium
        )

        panel.update(displayFrame: displayFrame, placement: placement)

        let localFrame = placement.rect(in: displayFrame.size)
        XCTAssertEqual(panel.frame.minX, displayFrame.minX + localFrame.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, displayFrame.minY + localFrame.minY, accuracy: 1)
        XCTAssertEqual(panel.frame.width, localFrame.width, accuracy: 1)
        XCTAssertEqual(panel.frame.height, localFrame.height, accuracy: 1)
    }

    func testPreviewControlsInvokeActionsAndExposeAccessibleHelp() {
        var disableCount = 0
        var openControlsCount = 0
        let panel = FacecamOverlayPanel(
            session: AVCaptureSession(),
            onDisableFacecam: { disableCount += 1 },
            onOpenFacecamControls: { openControlsCount += 1 }
        )

        panel.disableFacecamButton.performClick(nil)
        panel.openFacecamControlsButton.performClick(nil)

        XCTAssertEqual(disableCount, 1)
        XCTAssertEqual(openControlsCount, 1)
        XCTAssertEqual(panel.disableFacecamButton.accessibilityLabel(), "Disable Facecam")
        XCTAssertEqual(panel.openFacecamControlsButton.accessibilityLabel(), "Open Facecam Controls")
        XCTAssertEqual(
            panel.disableFacecamButton.toolTip,
            "Disable Facecam and stop the camera"
        )
        XCTAssertEqual(panel.openFacecamControlsButton.toolTip, "Open Facecam controls")
    }

    func testPreviewControlsReceiveClicksWhileTheRemainingSurfaceStaysDraggable() {
        let panel = FacecamOverlayPanel(session: AVCaptureSession())
        let displayFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        panel.update(displayFrame: displayFrame, placement: .default)
        panel.contentView?.layoutSubtreeIfNeeded()

        guard let contentView = panel.contentView else {
            return XCTFail("Expected overlay content view")
        }
        let closeCenter = contentView.convert(
            NSPoint(
                x: panel.disableFacecamButton.bounds.midX,
                y: panel.disableFacecamButton.bounds.midY
            ),
            from: panel.disableFacecamButton
        )

        XCTAssertTrue(contentView.hitTest(closeCenter) === panel.disableFacecamButton)
        XCTAssertTrue(
            contentView.hitTest(NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
                === contentView
        )
    }
}
