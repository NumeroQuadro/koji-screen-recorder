import CoreGraphics
import XCTest
@testable import Koji

final class SelectedDisplayOverlayMapperTests: XCTestCase {
    func testMapsAppKitBottomLeftPlacementToTopLeftOutputPixels() throws {
        let placement = FacecamPlacement(
            normalizedCenterX: 0.25,
            normalizedCenterY: 0.75,
            sizePreset: .small
        )
        let displayFrame = CGRect(x: 0, y: 0, width: 1_000, height: 500)

        let mapping = try XCTUnwrap(
            SelectedDisplayOverlayMapper.map(
                placement: placement,
                displayFrameInScreenPoints: displayFrame,
                pointPixelScale: 2,
                outputPixelSize: CapturePixelSize(width: 2_000, height: 1_000)
            )
        )
        let localRect = placement.rect(in: displayFrame.size)

        XCTAssertEqual(mapping.coordinateOrigin, .topLeft)
        XCTAssertEqual(mapping.rect.minX, localRect.minX * 2, accuracy: 0.000_001)
        XCTAssertEqual(mapping.rect.minY, (displayFrame.height - localRect.maxY) * 2, accuracy: 0.000_001)
        XCTAssertEqual(mapping.rect.width, localRect.width * 2, accuracy: 0.000_001)
        XCTAssertEqual(mapping.rect.height, localRect.height * 2, accuracy: 0.000_001)
    }

    func testNegativeSecondaryDisplayOriginDoesNotChangeLocalPlacement() throws {
        let placement = FacecamPlacement(
            normalizedCenterX: 0.6,
            normalizedCenterY: 0.3,
            sizePreset: .medium
        )
        let primary = try XCTUnwrap(
            SelectedDisplayOverlayMapper.map(
                placement: placement,
                displayFrameInScreenPoints: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                pointPixelScale: 2,
                outputPixelSize: CapturePixelSize(width: 3_840, height: 2_160)
            )
        )
        let secondary = try XCTUnwrap(
            SelectedDisplayOverlayMapper.map(
                placement: placement,
                displayFrameInScreenPoints: CGRect(x: -1_920, y: 220, width: 1_920, height: 1_080),
                pointPixelScale: 2,
                outputPixelSize: CapturePixelSize(width: 3_840, height: 2_160)
            )
        )

        assertEqual(primary.rect, secondary.rect)
    }

    func testOutputDownscalingPreservesRelativeGeometry() throws {
        let placement = FacecamPlacement(
            normalizedCenterX: 0.8,
            normalizedCenterY: 0.2,
            sizePreset: .large
        )
        let native = try XCTUnwrap(
            SelectedDisplayOverlayMapper.map(
                placement: placement,
                displayFrameInScreenPoints: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                pointPixelScale: 2,
                outputPixelSize: CapturePixelSize(width: 3_840, height: 2_160)
            )
        )
        let downscaled = try XCTUnwrap(
            SelectedDisplayOverlayMapper.map(
                placement: placement,
                displayFrameInScreenPoints: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                pointPixelScale: 2,
                outputPixelSize: CapturePixelSize(width: 1_920, height: 1_080)
            )
        )

        XCTAssertEqual(downscaled.rect.minX, native.rect.minX / 2, accuracy: 0.000_001)
        XCTAssertEqual(downscaled.rect.minY, native.rect.minY / 2, accuracy: 0.000_001)
        XCTAssertEqual(downscaled.rect.width, native.rect.width / 2, accuracy: 0.000_001)
        XCTAssertEqual(downscaled.rect.height, native.rect.height / 2, accuracy: 0.000_001)
    }

    func testInvalidGeometryIsRejected() {
        XCTAssertNil(
            SelectedDisplayOverlayMapper.map(
                placement: .default,
                displayFrameInScreenPoints: .zero,
                pointPixelScale: 2,
                outputPixelSize: CapturePixelSize(width: 1_920, height: 1_080)
            )
        )
        XCTAssertNil(
            SelectedDisplayOverlayMapper.map(
                placement: .default,
                displayFrameInScreenPoints: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                pointPixelScale: 0,
                outputPixelSize: CapturePixelSize(width: 1_920, height: 1_080)
            )
        )
    }

    private func assertEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: 0.000_001, file: file, line: line)
    }
}
