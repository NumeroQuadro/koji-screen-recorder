import CoreGraphics
import XCTest
@testable import Koji

final class CaptureTargetResolverTests: XCTestCase {
    private let inventory = CaptureTargetInventory(
        displayIDs: [10, 20],
        windowIDs: [30],
        applicationBundleIdentifiers: ["com.example.editor"]
    )

    func testValidExplicitSelectionsRemainSelected() {
        XCTAssertEqual(
            resolve(selectedToken: .display(20), preferredDisplayID: 10, primaryDisplayID: 10),
            .display(20)
        )
        XCTAssertEqual(
            resolve(selectedToken: .window(30), preferredDisplayID: 10, primaryDisplayID: 20),
            .window(30)
        )
        XCTAssertEqual(
            resolve(
                selectedToken: .application(bundleIdentifier: "com.example.editor"),
                preferredDisplayID: 10,
                primaryDisplayID: 20
            ),
            .application(bundleIdentifier: "com.example.editor", displayID: 20)
        )
    }

    func testStaleSelectionFallsBackToPreferredThenPrimaryThenFirstDisplay() {
        XCTAssertEqual(
            resolve(selectedToken: .window(999), preferredDisplayID: 20, primaryDisplayID: 10),
            .display(20)
        )
        XCTAssertEqual(
            resolve(selectedToken: .display(999), preferredDisplayID: 999, primaryDisplayID: 20),
            .display(20)
        )
        XCTAssertEqual(
            resolve(selectedToken: nil, preferredDisplayID: 999, primaryDisplayID: 999),
            .display(10)
        )
    }

    func testApplicationUsesFirstDisplayWhenPrimaryIsUnavailable() {
        XCTAssertEqual(
            resolve(
                selectedToken: .application(bundleIdentifier: "com.example.editor"),
                preferredDisplayID: 20,
                primaryDisplayID: 999
            ),
            .application(bundleIdentifier: "com.example.editor", displayID: 10)
        )
    }

    func testWindowCanResolveWithoutAnyDisplayButApplicationCannot() {
        let noDisplayInventory = CaptureTargetInventory(
            displayIDs: [],
            windowIDs: [30],
            applicationBundleIdentifiers: ["com.example.editor"]
        )

        XCTAssertEqual(
            CaptureTargetSelectionPolicy.resolve(
                selectedToken: .window(30),
                preferredDisplayID: nil,
                primaryDisplayID: nil,
                inventory: noDisplayInventory
            ),
            .window(30)
        )
        XCTAssertNil(
            CaptureTargetSelectionPolicy.resolve(
                selectedToken: .application(bundleIdentifier: "com.example.editor"),
                preferredDisplayID: nil,
                primaryDisplayID: nil,
                inventory: noDisplayInventory
            )
        )
    }

    func testWindowSelectionAloneScalesToFit() {
        XCTAssertFalse(CaptureTargetSelection.display(10).scalesToFit)
        XCTAssertTrue(CaptureTargetSelection.window(30).scalesToFit)
        XCTAssertFalse(
            CaptureTargetSelection.application(
                bundleIdentifier: "com.example.editor",
                displayID: 10
            ).scalesToFit
        )
    }

    func testPixelSizeRoundsScaledContentAndNeverReturnsZero() {
        XCTAssertEqual(
            CaptureTargetResolver.pixelSize(
                contentRect: CGRect(x: 0, y: 0, width: 100.4, height: 50.4),
                pointPixelScale: 2
            ),
            CapturePixelSize(width: 201, height: 101)
        )
        XCTAssertEqual(
            CaptureTargetResolver.pixelSize(contentRect: .zero, pointPixelScale: 2),
            CapturePixelSize(width: 1, height: 1)
        )
    }

    func testCaptureIsolationMatchesTheCurrentProcessBeforeBundleFallback() {
        XCTAssertTrue(
            CaptureIsolationPolicy.isCurrentProcess(
                applicationProcessID: 42,
                applicationBundleIdentifier: "com.example.renamed",
                currentProcessID: 42,
                currentBundleIdentifier: "com.koji.screenrecorder"
            )
        )
        XCTAssertTrue(
            CaptureIsolationPolicy.isCurrentProcess(
                applicationProcessID: 99,
                applicationBundleIdentifier: "com.koji.screenrecorder",
                currentProcessID: 42,
                currentBundleIdentifier: "com.koji.screenrecorder"
            )
        )
        XCTAssertFalse(
            CaptureIsolationPolicy.isCurrentProcess(
                applicationProcessID: 99,
                applicationBundleIdentifier: "com.example.editor",
                currentProcessID: 42,
                currentBundleIdentifier: "com.koji.screenrecorder"
            )
        )
    }

    private func resolve(
        selectedToken: CaptureSourceToken?,
        preferredDisplayID: CGDirectDisplayID?,
        primaryDisplayID: CGDirectDisplayID?
    ) -> CaptureTargetSelection? {
        CaptureTargetSelectionPolicy.resolve(
            selectedToken: selectedToken,
            preferredDisplayID: preferredDisplayID,
            primaryDisplayID: primaryDisplayID,
            inventory: inventory
        )
    }
}
