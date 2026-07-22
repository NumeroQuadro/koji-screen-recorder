import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let onboardingManager = OnboardingManager()
    private var statusItemManager: StatusItemManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if onboardingManager.hasCompletedOnboarding {
            startMenuBar()
            return
        }

        onboardingManager.showWelcomeScreen(
            openPopover: { [weak self] in
                self?.startMenuBar(openPopover: true)
            },
            onDismiss: { [weak self] in
                self?.startMenuBar()
            }
        )
    }

    private func startMenuBar(openPopover: Bool = false) {
        if statusItemManager == nil {
            statusItemManager = StatusItemManager(showWelcomeScreen: { [weak self] in
                guard let self else { return }
                self.onboardingManager.showWelcomeScreen(openPopover: { [weak self] in
                    self?.statusItemManager?.openPopover()
                })
            })
            statusItemManager?.start()
        }

        if openPopover {
            statusItemManager?.openPopover()
        }
    }
}
