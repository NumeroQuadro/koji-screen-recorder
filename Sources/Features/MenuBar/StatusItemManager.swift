import AppKit
import SwiftUI

@MainActor
final class StatusItemManager: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    private let recordingState: RecordingState
    private let recordingCoordinator: RecordingCoordinator
    private let permissionsState: PermissionsState
    private let cameraAccessController: CameraAccessController
    private let cameraCaptureService: CameraCaptureService
    private let preferences: Preferences
    private let facecamPlacementStore: FacecamPlacementStore
    private let updateManager: UpdateManager
    private let hotkeyManager: HotkeyManager
    private let settingsWindowController: SettingsWindowController
    private let notificationManager: NotificationManager
    private var recordingIndicator: RecordingIndicator?
    private var popoverDismissalController: PopoverDismissalController?
    private var screenParametersObserver: NSObjectProtocol?
    private let showWelcomeScreen: () -> Void

    private lazy var facecamOverlayController = FacecamOverlayController(
        preferences: preferences,
        placementStore: facecamPlacementStore,
        previewSession: cameraCaptureService.previewSession,
        onDisableFacecam: { [weak self] in
            Task { @MainActor [weak self] in
                await self?.recordingCoordinator.setFacecamEnabled(false)
            }
        },
        onOpenFacecamControls: { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.openPopover()
        }
    )

    init(showWelcomeScreen: @escaping () -> Void) {
        self.showWelcomeScreen = showWelcomeScreen
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        recordingState = RecordingState()
        permissionsState = PermissionsState()
        let preferences = Preferences()
        self.preferences = preferences
        facecamPlacementStore = FacecamPlacementStore(
            initialPlacement: preferences.facecamPlacement
        )
        cameraCaptureService = CameraCaptureService()
        cameraAccessController = CameraAccessController(
            permissionsState: permissionsState,
            preferences: preferences,
            discovery: AVFoundationCameraDeviceDiscovery(),
            captureService: cameraCaptureService
        )
        updateManager = UpdateManager()
        notificationManager = NotificationManager()
        recordingCoordinator = RecordingCoordinator(
            recordingState: recordingState,
            permissionsState: permissionsState,
            preferences: preferences,
            notificationManager: notificationManager,
            cameraAccessController: cameraAccessController,
            cameraFrameProvider: cameraCaptureService,
            facecamPlacementStore: facecamPlacementStore
        )
        hotkeyManager = HotkeyManager(preferences: preferences, recordingCoordinator: recordingCoordinator)
        settingsWindowController = SettingsWindowController(
            preferences: preferences,
            recordingCoordinator: recordingCoordinator,
            updateManager: updateManager,
            showWelcomeScreen: showWelcomeScreen
        )
        super.init()
    }

    func start() {
        configureStatusItem()
        configurePopover()
        preferences.ensureOutputDirectoryExists()
        notificationManager.start()
        updateManager.startAutomaticChecks()
        hotkeyManager.start()
        observeFacecamOverlayState()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFacecamOverlay()
            }
        }
        Task { [recordingCoordinator, cameraAccessController] in
            let startupRefresher = StatusItemStartupRefresher(
                recoverManagedRecordings: {
                    await recordingCoordinator.recoverOrphanedRecordings()
                },
                refreshMicrophones: {
                    await recordingCoordinator.refreshMicrophones()
                },
                restoreFacecam: {
                    await cameraAccessController.restorePersistedFacecamState()
                }
            )
            await startupRefresher.run()
        }

        #if DEBUG
        startRecordTestIfExplicitlyEnabled()
        #endif
    }

    deinit {
        MainActor.assumeIsolated {
            popoverDismissalController?.stop()
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    #if DEBUG
    private func startRecordTestIfExplicitlyEnabled() {
        guard let configuration = RecordTestLaunchPolicy.configuration(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        ) else {
            return
        }

        Task { [recordingCoordinator] in
            do {
                if configuration.disablesMicrophone {
                    recordingCoordinator.isMicrophoneEnabled = false
                }

                try await recordingCoordinator.startRecording()
                try await Task.sleep(for: .seconds(10))
                try await recordingCoordinator.stopRecording()
            } catch {
                print("Debug record test failed.")
            }

            NSApplication.shared.terminate(nil)
        }
    }
    #endif

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        recordingIndicator = RecordingIndicator(statusButton: button, recordingState: recordingState)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(statusItemClicked(_:))
        button.target = self
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 300, height: 360)
        let popover = self.popover
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                recordingState: recordingState,
                recordingCoordinator: recordingCoordinator,
                permissionsState: permissionsState,
                cameraAccessController: cameraAccessController,
                preferences: preferences,
                openSettings: { [settingsWindowController] in
                    settingsWindowController.show()
                }
            )
            .onExitCommand { [weak popover] in
                popover?.performClose(nil)
            }
        )
        popoverDismissalController = PopoverDismissalController(
            eventMonitor: AppKitPopoverEventMonitor(),
            popoverWindow: { [weak self] in
                self?.popover.contentViewController?.view.window
            },
            statusItemWindow: { [weak self] in
                self?.statusItem.button?.window
            },
            dismiss: { [weak self] in
                self?.dismissPopover()
            }
        )
    }

    private func observeFacecamOverlayState() {
        let presentation = withObservationTracking {
            currentFacecamOverlayPresentation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeFacecamOverlayState()
            }
        }

        synchronizeFacecamOverlay(with: presentation)
    }

    private func refreshFacecamOverlay() {
        synchronizeFacecamOverlay(with: currentFacecamOverlayPresentation)
    }

    private var currentFacecamOverlayPresentation: FacecamOverlayPresentation {
        FacecamOverlayPresentation(
            isVisible: cameraAccessController.canUseFacecam,
            displayID: selectedFacecamDisplayID,
            placement: preferences.facecamPlacement
        )
    }

    private func synchronizeFacecamOverlay(with presentation: FacecamOverlayPresentation) {
        facecamPlacementStore.set(presentation.placement)
        facecamOverlayController.synchronize(
            isVisible: presentation.isVisible,
            displayID: presentation.displayID
        )
    }

    private var selectedFacecamDisplayID: CGDirectDisplayID? {
        guard
            let token = CaptureSourceToken(rawValue: recordingCoordinator.selectedCaptureSourceToken),
            case let .display(displayID) = token
        else {
            return nil
        }
        return displayID
    }

    func openPopover() {
        if popover.isShown {
            return
        }

        showPopover()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }

        if event.type == .rightMouseUp || event.type == .rightMouseDown {
            dismissPopover()
            showStatusMenu(using: event)
        } else {
            togglePopover(sender)
        }
    }

    private func showStatusMenu(using event: NSEvent) {
        guard let button = statusItem.button else { return }
        NSMenu.popUpContextMenu(makeStatusMenu(), with: event, for: button)
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesFromMenu(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        checkForUpdatesItem.isEnabled = updateManager.canCheckForUpdates
        menu.addItem(checkForUpdatesItem)

        let microphoneItem = NSMenuItem(
            title: "Include Microphone",
            action: #selector(toggleMicrophoneFromMenu(_:)),
            keyEquivalent: ""
        )
        microphoneItem.target = self
        microphoneItem.state = recordingCoordinator.isMicrophoneEnabled ? .on : .off
        microphoneItem.isEnabled = recordingCoordinator.canToggleMicrophone
        menu.addItem(microphoneItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let welcomeItem = NSMenuItem(
            title: "Show Welcome Screen",
            action: #selector(showWelcomeFromMenu(_:)),
            keyEquivalent: ""
        )
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(Brand.appName)",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func checkForUpdatesFromMenu(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        updateManager.checkForUpdates()
    }

    @objc private func toggleMicrophoneFromMenu(_ sender: Any?) {
        Task { [recordingCoordinator] in
            await recordingCoordinator.toggleMicrophoneEnabled()
        }
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        settingsWindowController.show()
    }

    @objc private func showWelcomeFromMenu(_ sender: Any?) {
        showWelcomeScreen()
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            dismissPopover(sender)
            return
        }

        showPopover()
    }

    private func dismissPopover(_ sender: Any? = nil) {
        guard popover.isShown else { return }
        popover.performClose(sender)
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension StatusItemManager: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        popoverDismissalController?.start()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverDismissalController?.stop()
    }
}

private struct FacecamOverlayPresentation {
    let isVisible: Bool
    let displayID: CGDirectDisplayID?
    let placement: FacecamPlacement
}
