import AppKit
import AVFoundation
import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var isMirrored = true

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session, isMirrored: isMirrored)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.update(session: session, isMirrored: isMirrored)
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession, isMirrored: Bool) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        update(session: session, isMirrored: isMirrored)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func update(session: AVCaptureSession, isMirrored: Bool) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }

        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else {
            return
        }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = isMirrored
    }
}
