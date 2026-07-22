import AppKit
import AVFoundation
import CoreGraphics

@MainActor
final class FacecamOverlayController {
    private let preferences: Preferences
    private let placementStore: FacecamPlacementStore
    private let previewSession: AVCaptureSession
    private let onDisableFacecam: () -> Void
    private let onOpenFacecamControls: () -> Void
    private var panel: FacecamOverlayPanel?

    init(
        preferences: Preferences,
        placementStore: FacecamPlacementStore,
        previewSession: AVCaptureSession,
        onDisableFacecam: @escaping () -> Void,
        onOpenFacecamControls: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.placementStore = placementStore
        self.previewSession = previewSession
        self.onDisableFacecam = onDisableFacecam
        self.onOpenFacecamControls = onOpenFacecamControls
    }

    func synchronize(isVisible: Bool, displayID: CGDirectDisplayID?) {
        guard
            isVisible,
            let displayID,
            let screen = Self.screen(for: displayID)
        else {
            hide()
            return
        }

        let clampedPlacement = preferences.facecamPlacement.clamped(in: screen.frame.size)
        placementStore.set(clampedPlacement)
        if preferences.facecamPlacement != clampedPlacement {
            preferences.facecamPlacement = clampedPlacement
        }

        let panel = panel ?? makePanel()
        panel.update(
            displayFrame: screen.frame,
            placement: clampedPlacement
        )
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FacecamOverlayPanel {
        let panel = FacecamOverlayPanel(
            session: previewSession,
            onDisableFacecam: onDisableFacecam,
            onOpenFacecamControls: onOpenFacecamControls
        )
        panel.onFrameChange = { [weak self, weak panel] frame in
            guard let self, let panel else { return }
            let displayFrame = panel.displayFrame
            guard displayFrame.width > 0, displayFrame.height > 0 else { return }

            let centerInDisplay = CGPoint(
                x: frame.midX - displayFrame.minX,
                y: frame.midY - displayFrame.minY
            )
            let placement = self.preferences.facecamPlacement.moved(
                to: centerInDisplay,
                in: displayFrame.size
            )
            self.placementStore.set(placement)
            if self.preferences.facecamPlacement != placement {
                self.preferences.facecamPlacement = placement
            }
        }
        self.panel = panel
        return panel
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard
                let screenNumber = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == displayID
        }
    }
}

final class FacecamOverlayPanel: NSPanel {
    fileprivate var displayFrame: CGRect = .zero
    var onFrameChange: ((CGRect) -> Void)? {
        didSet { overlayView.onFrameChange = onFrameChange }
    }

    private let overlayView: FacecamOverlayContentView

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var disableFacecamButton: NSButton { overlayView.disableFacecamButton }
    var openFacecamControlsButton: NSButton { overlayView.openFacecamControlsButton }

    init(
        session: AVCaptureSession,
        onDisableFacecam: @escaping () -> Void = {},
        onOpenFacecamControls: @escaping () -> Void = {}
    ) {
        overlayView = FacecamOverlayContentView(
            session: session,
            onDisableFacecam: onDisableFacecam,
            onOpenFacecamControls: onOpenFacecamControls
        )
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlayView
    }

    func update(displayFrame: CGRect, placement: FacecamPlacement) {
        self.displayFrame = displayFrame
        overlayView.displayFrame = displayFrame

        let frameInDisplay = placement.rect(in: displayFrame.size)
        let globalFrame = frameInDisplay.offsetBy(
            dx: displayFrame.minX,
            dy: displayFrame.minY
        )
        setFrame(globalFrame, display: false)
    }
}

private final class FacecamOverlayContentView: NSView {
    var displayFrame: CGRect = .zero
    var onFrameChange: ((CGRect) -> Void)?

    fileprivate let disableFacecamButton: NSButton
    fileprivate let openFacecamControlsButton: NSButton

    private let previewView: CameraPreviewNSView
    private let onDisableFacecam: () -> Void
    private let onOpenFacecamControls: () -> Void
    private var initialMouseLocation: CGPoint?
    private var initialPanelFrame: CGRect?
    private var didPushDragCursor = false

    init(
        session: AVCaptureSession,
        onDisableFacecam: @escaping () -> Void,
        onOpenFacecamControls: @escaping () -> Void
    ) {
        previewView = CameraPreviewNSView(session: session, isMirrored: true)
        disableFacecamButton = Self.makeControlButton(
            symbolName: "xmark",
            accessibilityLabel: "Disable Facecam",
            toolTip: "Disable Facecam and stop the camera"
        )
        openFacecamControlsButton = Self.makeControlButton(
            symbolName: "arrow.up.left",
            accessibilityLabel: "Open Facecam Controls",
            toolTip: "Open Facecam controls"
        )
        self.onDisableFacecam = onDisableFacecam
        self.onOpenFacecamControls = onOpenFacecamControls
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        layer?.borderWidth = 1

        previewView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewView)
        addSubview(disableFacecamButton)
        addSubview(openFacecamControlsButton)

        disableFacecamButton.target = self
        disableFacecamButton.action = #selector(disableFacecam)
        openFacecamControlsButton.target = self
        openFacecamControlsButton.action = #selector(openFacecamControls)

        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewView.topAnchor.constraint(equalTo: topAnchor),
            previewView.bottomAnchor.constraint(equalTo: bottomAnchor),
            openFacecamControlsButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            openFacecamControlsButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            openFacecamControlsButton.widthAnchor.constraint(equalToConstant: 36),
            openFacecamControlsButton.heightAnchor.constraint(equalToConstant: 36),
            disableFacecamButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            disableFacecamButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            disableFacecamButton.widthAnchor.constraint(equalToConstant: 36),
            disableFacecamButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }

        for button in [disableFacecamButton, openFacecamControlsButton] {
            let pointInButton = convert(point, to: button)
            if button.bounds.contains(pointInButton) {
                return button
            }
        }

        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(openFacecamControlsButton.frame, cursor: .arrow)
        addCursorRect(disableFacecamButton.frame, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialMouseLocation = window.convertPoint(toScreen: event.locationInWindow)
        initialPanelFrame = window.frame
        NSCursor.closedHand.push()
        didPushDragCursor = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let window,
            let initialMouseLocation,
            let initialPanelFrame
        else {
            return
        }

        let currentMouseLocation = window.convertPoint(toScreen: event.locationInWindow)
        let deltaX = currentMouseLocation.x - initialMouseLocation.x
        let deltaY = currentMouseLocation.y - initialMouseLocation.y
        var candidateFrame = initialPanelFrame.offsetBy(dx: deltaX, dy: deltaY)
        candidateFrame.origin.x = candidateFrame.origin.x.clamped(
            to: displayFrame.minX...(displayFrame.maxX - candidateFrame.width)
        )
        candidateFrame.origin.y = candidateFrame.origin.y.clamped(
            to: displayFrame.minY...(displayFrame.maxY - candidateFrame.height)
        )

        window.setFrameOrigin(candidateFrame.origin)
        onFrameChange?(candidateFrame)
    }

    override func mouseUp(with event: NSEvent) {
        initialMouseLocation = nil
        initialPanelFrame = nil
        if didPushDragCursor {
            NSCursor.pop()
            didPushDragCursor = false
        }
    }

    @objc private func disableFacecam() {
        onDisableFacecam()
    }

    @objc private func openFacecamControls() {
        onOpenFacecamControls()
    }

    private static func makeControlButton(
        symbolName: String,
        accessibilityLabel: String,
        toolTip: String
    ) -> NSButton {
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.focusRingType = .none
        button.toolTip = toolTip
        button.setAccessibilityLabel(accessibilityLabel)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        button.layer?.cornerRadius = 10
        button.layer?.cornerCurve = .continuous
        return button
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
