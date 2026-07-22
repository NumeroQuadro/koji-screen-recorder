import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let preferences: Preferences
    private let recordingCoordinator: RecordingCoordinator
    private let updateManager: UpdateManager
    private let showWelcomeScreen: () -> Void
    private var window: NSWindow?

    init(
        preferences: Preferences,
        recordingCoordinator: RecordingCoordinator,
        updateManager: UpdateManager,
        showWelcomeScreen: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.recordingCoordinator = recordingCoordinator
        self.updateManager = updateManager
        self.showWelcomeScreen = showWelcomeScreen
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }

        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(
            preferences: preferences,
            recordingCoordinator: recordingCoordinator,
            updateManager: updateManager,
            showWelcomeScreen: showWelcomeScreen
        )
        let controller = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: controller)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setContentSize(NSSize(width: 560, height: 420))
        return window
    }
}
