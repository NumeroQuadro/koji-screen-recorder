import CoreGraphics
import Foundation

enum FacecamSizePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    var normalizedWidth: Double {
        switch self {
        case .small: 0.16
        case .medium: 0.22
        case .large: 0.30
        }
    }
}

struct FacecamPlacement: Codable, Equatable, Sendable {
    static let defaultAspectRatio = 16.0 / 9.0
    static let minimumWidth: CGFloat = 180
    static let `default` = FacecamPlacement(
        normalizedCenterX: 0.82,
        normalizedCenterY: 0.18,
        sizePreset: .medium,
        aspectRatio: defaultAspectRatio
    )

    var normalizedCenterX: Double
    var normalizedCenterY: Double
    var sizePreset: FacecamSizePreset
    var aspectRatio: Double

    init(
        normalizedCenterX: Double,
        normalizedCenterY: Double,
        sizePreset: FacecamSizePreset,
        aspectRatio: Double = FacecamPlacement.defaultAspectRatio
    ) {
        self.normalizedCenterX = normalizedCenterX
        self.normalizedCenterY = normalizedCenterY
        self.sizePreset = sizePreset
        self.aspectRatio = aspectRatio
        self = sanitized()
    }

    var normalizedCenter: CGPoint {
        CGPoint(x: normalizedCenterX, y: normalizedCenterY)
    }

    func rect(in displaySize: CGSize) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0 else { return .zero }

        let overlaySize = size(in: displaySize)
        let halfWidth = overlaySize.width / 2
        let halfHeight = overlaySize.height / 2
        let desiredCenter = CGPoint(
            x: CGFloat(normalizedCenterX) * displaySize.width,
            y: CGFloat(normalizedCenterY) * displaySize.height
        )
        let center = CGPoint(
            x: desiredCenter.x.clamped(to: halfWidth...(displaySize.width - halfWidth)),
            y: desiredCenter.y.clamped(to: halfHeight...(displaySize.height - halfHeight))
        )

        return CGRect(
            x: center.x - halfWidth,
            y: center.y - halfHeight,
            width: overlaySize.width,
            height: overlaySize.height
        )
    }

    func moved(to center: CGPoint, in displaySize: CGSize) -> FacecamPlacement {
        guard displaySize.width > 0, displaySize.height > 0 else { return sanitized() }

        var placement = self
        placement.normalizedCenterX = Double(center.x / displaySize.width)
        placement.normalizedCenterY = Double(center.y / displaySize.height)
        return placement.clamped(in: displaySize)
    }

    func applyingSizePreset(
        _ newPreset: FacecamSizePreset,
        in displaySize: CGSize
    ) -> FacecamPlacement {
        var placement = self
        placement.sizePreset = newPreset
        return placement.clamped(in: displaySize)
    }

    func clamped(in displaySize: CGSize) -> FacecamPlacement {
        guard displaySize.width > 0, displaySize.height > 0 else { return sanitized() }

        let overlayRect = sanitized().rect(in: displaySize)
        var placement = sanitized()
        placement.normalizedCenterX = Double(overlayRect.midX / displaySize.width)
        placement.normalizedCenterY = Double(overlayRect.midY / displaySize.height)
        return placement
    }

    func sanitized() -> FacecamPlacement {
        var placement = self
        placement.normalizedCenterX = Self.sanitizedUnitValue(normalizedCenterX, fallback: 0.82)
        placement.normalizedCenterY = Self.sanitizedUnitValue(normalizedCenterY, fallback: 0.18)
        if !aspectRatio.isFinite || aspectRatio <= 0 {
            placement.aspectRatio = Self.defaultAspectRatio
        }
        return placement
    }

    private func size(in displaySize: CGSize) -> CGSize {
        let availableWidth = max(0, displaySize.width)
        let availableHeight = max(0, displaySize.height)
        guard availableWidth > 0, availableHeight > 0 else { return .zero }

        let minimumWidth = min(Self.minimumWidth, availableWidth)
        let desiredWidth = max(
            CGFloat(sizePreset.normalizedWidth) * availableWidth,
            minimumWidth
        )
        let width = min(
            desiredWidth,
            availableWidth,
            availableHeight * CGFloat(aspectRatio)
        )
        return CGSize(width: width, height: width / CGFloat(aspectRatio))
    }

    private static func sanitizedUnitValue(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return value.clamped(to: 0...1)
    }
}

final class FacecamPlacementStore: @unchecked Sendable {
    private let lock = NSLock()
    private var placement: FacecamPlacement

    init(initialPlacement: FacecamPlacement = .default) {
        placement = initialPlacement.sanitized()
    }

    func snapshot() -> FacecamPlacement {
        lock.withLock { placement }
    }

    @discardableResult
    func set(_ newPlacement: FacecamPlacement) -> FacecamPlacement {
        lock.withLock {
            placement = newPlacement.sanitized()
            return placement
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
