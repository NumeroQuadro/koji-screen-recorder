import CoreGraphics
import XCTest
@testable import Koji

final class FacecamPlacementTests: XCTestCase {
    func testRectPreservesAspectRatioAndRemainsInsideDisplay() {
        let placement = FacecamPlacement(
            normalizedCenterX: 1,
            normalizedCenterY: 0,
            sizePreset: .large
        )
        let displaySize = CGSize(width: 1_512, height: 982)

        let rect = placement.rect(in: displaySize)

        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, displaySize.width)
        XCTAssertLessThanOrEqual(rect.maxY, displaySize.height)
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.000_001)
    }

    func testMovingNormalizesAndClampsTheCompleteOverlay() {
        let displaySize = CGSize(width: 1_920, height: 1_080)

        let moved = FacecamPlacement.default.moved(
            to: CGPoint(x: -500, y: 2_000),
            in: displaySize
        )
        let rect = moved.rect(in: displaySize)

        XCTAssertEqual(rect.minX, 0, accuracy: 0.000_001)
        XCTAssertEqual(rect.maxY, displaySize.height, accuracy: 0.000_001)
    }

    func testNormalizedPlacementRestoresEquivalentRelativePositionAcrossResolutions() {
        let placement = FacecamPlacement(
            normalizedCenterX: 0.35,
            normalizedCenterY: 0.64,
            sizePreset: .small
        )

        let firstRect = placement.rect(in: CGSize(width: 1_920, height: 1_080))
        let secondRect = placement.rect(in: CGSize(width: 3_840, height: 2_160))

        XCTAssertEqual(secondRect.midX / 3_840, firstRect.midX / 1_920, accuracy: 0.000_001)
        XCTAssertEqual(secondRect.midY / 2_160, firstRect.midY / 1_080, accuracy: 0.000_001)
        XCTAssertEqual(secondRect.width / 3_840, firstRect.width / 1_920, accuracy: 0.000_001)
    }

    func testSizePresetChangesDimensionsWithoutMovingCenterWhenThereIsRoom() {
        let displaySize = CGSize(width: 2_560, height: 1_440)
        let placement = FacecamPlacement(
            normalizedCenterX: 0.5,
            normalizedCenterY: 0.5,
            sizePreset: .small
        )

        let larger = placement.applyingSizePreset(.large, in: displaySize)
        let smallRect = placement.rect(in: displaySize)
        let largeRect = larger.rect(in: displaySize)

        XCTAssertGreaterThan(largeRect.width, smallRect.width)
        XCTAssertEqual(largeRect.midX, smallRect.midX, accuracy: 0.000_001)
        XCTAssertEqual(largeRect.midY, smallRect.midY, accuracy: 0.000_001)
    }

    func testSmallDisplaysStillProduceAContainedUsableOverlay() {
        let displaySize = CGSize(width: 240, height: 120)
        let rect = FacecamPlacement.default.rect(in: displaySize)

        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertLessThanOrEqual(rect.width, displaySize.width)
        XCTAssertLessThanOrEqual(rect.height, displaySize.height)
    }

    func testPlacementStorePublishesLatestThreadSafeSnapshot() {
        let store = FacecamPlacementStore()
        let expected = FacecamPlacement(
            normalizedCenterX: 0.25,
            normalizedCenterY: 0.75,
            sizePreset: .large
        )

        store.set(expected)

        XCTAssertEqual(store.snapshot(), expected)
    }
}
