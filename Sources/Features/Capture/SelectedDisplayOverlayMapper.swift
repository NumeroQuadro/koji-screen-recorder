import CoreGraphics

struct SelectedDisplayOverlayMapping: Equatable, Sendable {
    enum CoordinateOrigin: Equatable, Sendable {
        case topLeft
    }

    let rect: CGRect
    let coordinateOrigin: CoordinateOrigin
}

enum SelectedDisplayOverlayMapper {
    static func map(
        placement: FacecamPlacement,
        displayFrameInScreenPoints: CGRect,
        pointPixelScale: CGFloat,
        outputPixelSize: CapturePixelSize
    ) -> SelectedDisplayOverlayMapping? {
        guard
            displayFrameInScreenPoints.width > 0,
            displayFrameInScreenPoints.height > 0,
            pointPixelScale.isFinite,
            pointPixelScale > 0,
            outputPixelSize.width > 0,
            outputPixelSize.height > 0
        else {
            return nil
        }

        let localRect = placement.rect(in: displayFrameInScreenPoints.size)
        let globalAppKitRect = localRect.offsetBy(
            dx: displayFrameInScreenPoints.minX,
            dy: displayFrameInScreenPoints.minY
        )
        let sourcePixelSize = CGSize(
            width: displayFrameInScreenPoints.width * pointPixelScale,
            height: displayFrameInScreenPoints.height * pointPixelScale
        )
        let outputSize = CGSize(
            width: outputPixelSize.width,
            height: outputPixelSize.height
        )
        let outputScaleX = outputSize.width / sourcePixelSize.width
        let outputScaleY = outputSize.height / sourcePixelSize.height

        let localMinX = globalAppKitRect.minX - displayFrameInScreenPoints.minX
        let localMaxY = globalAppKitRect.maxY - displayFrameInScreenPoints.minY
        let rect = CGRect(
            x: localMinX * pointPixelScale * outputScaleX,
            y: outputSize.height - (localMaxY * pointPixelScale * outputScaleY),
            width: globalAppKitRect.width * pointPixelScale * outputScaleX,
            height: globalAppKitRect.height * pointPixelScale * outputScaleY
        )

        return SelectedDisplayOverlayMapping(
            rect: rect.intersection(CGRect(origin: .zero, size: outputSize)),
            coordinateOrigin: .topLeft
        )
    }
}
