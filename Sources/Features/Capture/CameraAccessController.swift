import AVFoundation
import Observation

@MainActor
@Observable
final class CameraAccessController {
    private(set) var isFacecamEnabled = false
    private(set) var isRequestingAuthorization = false
    private(set) var accessState: CameraAccessState
    private(set) var cameraOptions: [CameraOption] = []
    private(set) var selectedCameraID: String?
    private(set) var selection: CameraSelection
    private(set) var captureState: CameraCaptureState = .inactive
    private(set) var negotiatedFormat: CameraCaptureFormat?

    @ObservationIgnored private let permissionsState: PermissionsState
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let discovery: any CameraDeviceDiscovery
    @ObservationIgnored private let captureService: any CameraCaptureServicing
    @ObservationIgnored private var isRecordingConsumerActive = false

    init(
        permissionsState: PermissionsState,
        preferences: Preferences,
        discovery: any CameraDeviceDiscovery,
        captureService: any CameraCaptureServicing
    ) {
        self.permissionsState = permissionsState
        self.preferences = preferences
        self.discovery = discovery
        self.captureService = captureService
        accessState = Self.authorizationState(for: permissionsState.camera)
        selection = preferences.cameraSelection

        captureService.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleCaptureEvent(event)
            }
        }
    }

    convenience init(
        permissionsState: PermissionsState,
        preferences: Preferences
    ) {
        self.init(
            permissionsState: permissionsState,
            preferences: preferences,
            discovery: AVFoundationCameraDeviceDiscovery(),
            captureService: CameraCaptureService()
        )
    }

    var previewSession: AVCaptureSession {
        captureService.previewSession
    }

    var canUseFacecam: Bool {
        isFacecamEnabled
            && accessState == .authorized
            && selectedCameraID != nil
            && captureState.isProvidingFrames
    }

    func setFacecamEnabled(_ isEnabled: Bool) async {
        preferences.isFacecamEnabled = isEnabled

        if !isEnabled {
            await disableFacecam()
            return
        }

        guard !isFacecamEnabled else { return }
        isFacecamEnabled = true
        await authorizeAndDiscoverIfNeeded()
    }

    func restorePersistedFacecamState() async {
        guard preferences.isFacecamEnabled else { return }
        await setFacecamEnabled(true)
    }

    func refreshAfterSystemSettingsChange() async {
        permissionsState.refreshCamera()
        guard isFacecamEnabled else {
            accessState = Self.authorizationState(for: permissionsState.camera)
            return
        }

        await refreshForCurrentAuthorization()
    }

    func selectCamera(_ newSelection: CameraSelection) async {
        selection = newSelection
        preferences.cameraSelection = newSelection

        if case let .manual(deviceID) = newSelection {
            discovery.setUserPreferredCamera(deviceID: deviceID)
        }

        refreshDevices()
        await reconcilePreview()
    }

    func retryCapture() async {
        guard isFacecamEnabled else { return }
        await refreshForCurrentAuthorization()
    }

    func setRecordingConsumerActive(_ isActive: Bool) async {
        guard isActive else {
            await captureService.stopRecording()
            isRecordingConsumerActive = false
            if isFacecamEnabled, captureState.isProvidingFrames {
                captureState = .previewing
            } else if !isFacecamEnabled {
                captureState = .inactive
            }
            return
        }

        guard
            isFacecamEnabled,
            accessState == .authorized,
            let selectedCameraID
        else {
            return
        }

        captureState = .starting
        do {
            negotiatedFormat = try await captureService.startRecording(deviceID: selectedCameraID)
            isRecordingConsumerActive = true
            captureState = .previewingAndRecording
        } catch let error as CameraCaptureError {
            captureState = .failed(error)
        } catch {
            captureState = .failed(.failedToStart)
        }
    }

    private func authorizeAndDiscoverIfNeeded() async {
        permissionsState.refreshCamera()

        if CameraAuthorizationPolicy.shouldRequestPermission(
            isFacecamAction: true,
            permissionStatus: permissionsState.camera
        ) {
            guard !isRequestingAuthorization else { return }
            isRequestingAuthorization = true
            await permissionsState.requestCamera()
            isRequestingAuthorization = false
        }

        guard isFacecamEnabled else { return }
        await refreshForCurrentAuthorization()
    }

    private func refreshForCurrentAuthorization() async {
        guard permissionsState.camera == .authorized else {
            discovery.stopMonitoring()
            await captureService.stopPreview()
            await captureService.stopRecording()
            isRecordingConsumerActive = false
            cameraOptions = []
            selectedCameraID = nil
            negotiatedFormat = nil
            captureState = .inactive
            accessState = Self.authorizationState(for: permissionsState.camera)
            return
        }

        discovery.startMonitoring { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshDevicesAndCapture()
            }
        }
        refreshDevices()
        await reconcilePreview()
    }

    private func refreshDevicesAndCapture() async {
        refreshDevices()
        await reconcilePreview()
    }

    private func refreshDevices() {
        guard isFacecamEnabled, permissionsState.camera == .authorized else { return }

        let snapshot = discovery.currentSnapshot()
        cameraOptions = snapshot.cameras

        switch selection {
        case .automatic:
            let preferredCamera = snapshot.systemPreferredCameraID.flatMap { preferredID in
                snapshot.cameras.first { $0.id == preferredID }
            }
            selectedCameraID = (preferredCamera ?? snapshot.cameras.first)?.id
            accessState = selectedCameraID == nil ? .unavailable : .authorized

        case let .manual(deviceID):
            if snapshot.cameras.contains(where: { $0.id == deviceID }) {
                selectedCameraID = deviceID
                accessState = .authorized
            } else {
                selectedCameraID = nil
                accessState = .disconnected
            }
        }
    }

    private func reconcilePreview() async {
        guard
            isFacecamEnabled,
            permissionsState.camera == .authorized,
            let selectedCameraID
        else {
            await captureService.stopPreview()
            negotiatedFormat = nil
            captureState = isRecordingConsumerActive ? .recording : .inactive
            return
        }

        captureState = .starting
        do {
            let format = try await captureService.startPreview(deviceID: selectedCameraID)
            guard isFacecamEnabled, self.selectedCameraID == selectedCameraID else {
                await captureService.stopPreview()
                return
            }
            negotiatedFormat = format
            captureState = isRecordingConsumerActive ? .previewingAndRecording : .previewing
        } catch let error as CameraCaptureError {
            negotiatedFormat = nil
            captureState = .failed(error)
        } catch {
            negotiatedFormat = nil
            captureState = .failed(.failedToStart)
        }
    }

    private func handleCaptureEvent(_ event: CameraCaptureEvent) async {
        guard isFacecamEnabled else { return }

        switch event {
        case .interrupted:
            captureState = .failed(.interrupted)
        case .runtimeFailure:
            captureState = .failed(.runtimeFailure)
        case .interruptionEnded:
            await reconcilePreview()
        }
    }

    private func disableFacecam() async {
        isFacecamEnabled = false
        isRequestingAuthorization = false
        discovery.stopMonitoring()
        await captureService.stopPreview()
        await captureService.stopRecording()
        isRecordingConsumerActive = false
        cameraOptions = []
        selectedCameraID = nil
        negotiatedFormat = nil
        captureState = .inactive
        accessState = Self.authorizationState(for: permissionsState.camera)
    }

    private static func authorizationState(for status: AVAuthorizationStatus) -> CameraAccessState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .restricted
        }
    }
}
