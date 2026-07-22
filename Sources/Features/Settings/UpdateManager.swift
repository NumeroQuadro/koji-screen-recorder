import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateManager: NSObject {
    var canCheckForUpdates: Bool = false
    var lastUpdateCheck: Date?

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    private let userDriver: SPUStandardUserDriver
    private var updater: SPUUpdater!
    private var didStartUpdater = false
    private var canCheckObservation: NSKeyValueObservation?

    override init() {
        userDriver = SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil)
        super.init()

        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: self
        )

        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            guard let self else { return }
            Task { @MainActor in
                self.canCheckForUpdates = updater.canCheckForUpdates
            }
        }

        refreshState()
    }

    func startAutomaticChecks() {
        guard !didStartUpdater else { return }

        do {
            try updater.start()
            didStartUpdater = true
        } catch {
            didStartUpdater = false
            NSLog("Sparkle startUpdater failed: \(error)")
        }

        refreshState()
    }

    func checkForUpdates() {
        if !didStartUpdater {
            startAutomaticChecks()
        }

        guard updater.canCheckForUpdates else {
            refreshState()
            return
        }

        updater.checkForUpdates()
        refreshState()
    }

    private func refreshState() {
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheck = updater.lastUpdateCheckDate
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("Sparkle update aborted: \(error)")
        refreshState()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            NSLog("Sparkle update cycle finished with error (\(updateCheck)): \(error)")
        }
        refreshState()
    }
}
