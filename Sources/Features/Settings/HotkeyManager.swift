import AppKit
import Observation

@MainActor
final class HotkeyManager {
    private let preferences: Preferences
    private let recordingCoordinator: RecordingCoordinator

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(preferences: Preferences, recordingCoordinator: RecordingCoordinator) {
        self.preferences = preferences
        self.recordingCoordinator = recordingCoordinator
    }

    func start() {
        registerMonitors()
        observeHotkeyChanges()
    }

    func stop() {
        unregisterMonitors()
    }

    private func observeHotkeyChanges() {
        withObservationTracking {
            _ = preferences.globalHotkey
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.registerMonitors()
                self?.observeHotkeyChanges()
            }
        }
    }

    private func registerMonitors() {
        unregisterMonitors()

        guard let hotkey = preferences.globalHotkey else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            self.handleKeyDown(event, hotkey: hotkey)
        }

        if globalMonitor == nil {
            print("Warning: global hotkey monitor failed to register; falling back to menu bar controls.")
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.handleKeyDown(event, hotkey: hotkey)
            return event
        }
    }

    private func unregisterMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent, hotkey: KeyCombo) {
        guard !event.isARepeat else { return }
        guard hotkey.matches(event: event) else { return }

        Task { @MainActor [weak self] in
            await self?.recordingCoordinator.toggleRecording()
        }
    }
}
