import AppKit
import SwiftUI

@MainActor
final class OnboardingManager: NSObject {
    private let userDefaults: UserDefaults
    private var window: NSWindow?
    private var didCompleteInSession = false
    private var onDismiss: (() -> Void)?

    private static let completionKey = "hasCompletedOnboarding"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        super.init()
    }

    var hasCompletedOnboarding: Bool {
        userDefaults.bool(forKey: Self.completionKey)
    }

    func showIfNeeded(openPopover: @escaping () -> Void) {
        guard !hasCompletedOnboarding else { return }
        showWelcomeScreen(openPopover: openPopover)
    }

    func showWelcomeScreen(openPopover: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        didCompleteInSession = false
        self.onDismiss = onDismiss

        let view = OnboardingView(onStartRecording: { [weak self] in
            guard let self else { return }
            self.didCompleteInSession = true
            self.userDefaults.set(true, forKey: Self.completionKey)
            self.closeWindow()
            openPopover()
        })
        .tint(Brand.accentColor)

        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = ""
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)

        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        window.setContentSize(NSSize(width: 500, height: 400))
        window.center()

        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWindow() {
        guard let window else { return }
        window.close()
        self.window = nil
    }
}

extension OnboardingManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
        if !didCompleteInSession {
            onDismiss?()
        }
        didCompleteInSession = false
        onDismiss = nil
    }
}
