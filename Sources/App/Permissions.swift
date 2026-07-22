import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit

enum ScreenRecordingPermissionStatus: Equatable {
    case unknown
    case granted
    case denied
}

protocol MicrophoneAuthorizationClient {
    func authorizationStatus() -> AVAuthorizationStatus
    func requestAccess() async -> Bool
}

struct SystemMicrophoneAuthorizationClient: MicrophoneAuthorizationClient {
    func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

protocol CameraAuthorizationClient {
    func authorizationStatus() -> AVAuthorizationStatus
    func requestAccess() async -> Bool
}

struct SystemCameraAuthorizationClient: CameraAuthorizationClient {
    func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

enum CameraAuthorizationPolicy {
    static func shouldRequestPermission(
        isFacecamAction: Bool,
        permissionStatus: AVAuthorizationStatus
    ) -> Bool {
        isFacecamAction && permissionStatus == .notDetermined
    }
}

enum Permissions {
    static func screenRecordingStatus() async -> ScreenRecordingPermissionStatus {
        do {
            _ = try await SCShareableContent.current
            return .granted
        } catch {
            let nsError = error as NSError
            print("SCShareableContent.current failed: domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")
            return .denied
        }
    }

    static func requestScreenRecordingPermission() async -> Bool {
        await screenRecordingStatus() == .granted
    }

    static func microphoneAuthorizationStatus(
        using client: any MicrophoneAuthorizationClient = SystemMicrophoneAuthorizationClient()
    ) -> AVAuthorizationStatus {
        client.authorizationStatus()
    }

    static func requestMicrophonePermission(
        using client: any MicrophoneAuthorizationClient = SystemMicrophoneAuthorizationClient()
    ) async -> Bool {
        let permissionStatus = client.authorizationStatus()

        guard MicrophoneCapturePolicy.shouldRequestPermission(
            isMicrophoneEnabled: true,
            permissionStatus: permissionStatus
        ) else {
            return permissionStatus == .authorized
        }

        return await client.requestAccess()
    }

    static func cameraAuthorizationStatus(
        using client: any CameraAuthorizationClient = SystemCameraAuthorizationClient()
    ) -> AVAuthorizationStatus {
        client.authorizationStatus()
    }

    static func requestCameraPermission(
        using client: any CameraAuthorizationClient = SystemCameraAuthorizationClient()
    ) async -> Bool {
        let status = client.authorizationStatus()
        guard CameraAuthorizationPolicy.shouldRequestPermission(
            isFacecamAction: true,
            permissionStatus: status
        ) else {
            return status == .authorized
        }

        return await client.requestAccess()
    }

    static func openScreenRecordingSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func openCameraSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
@Observable
final class PermissionsState {
    var screenRecording: ScreenRecordingPermissionStatus = .unknown
    var microphone: AVAuthorizationStatus
    // Camera authorization is intentionally unknown until an explicit Facecam action.
    // Even querying AVCaptureDevice's video status can initialize CMIO and enumerate devices.
    var camera: AVAuthorizationStatus = .notDetermined

    @ObservationIgnored private let microphoneAuthorizationClient: any MicrophoneAuthorizationClient
    @ObservationIgnored private let cameraAuthorizationClient: any CameraAuthorizationClient

    init(
        cameraAuthorizationClient: any CameraAuthorizationClient = SystemCameraAuthorizationClient(),
        microphoneAuthorizationClient: any MicrophoneAuthorizationClient = SystemMicrophoneAuthorizationClient()
    ) {
        self.cameraAuthorizationClient = cameraAuthorizationClient
        self.microphoneAuthorizationClient = microphoneAuthorizationClient
        microphone = Permissions.microphoneAuthorizationStatus(using: microphoneAuthorizationClient)
    }

    func refresh() async {
        screenRecording = await Permissions.screenRecordingStatus()
        refreshMicrophone()
    }

    func requestScreenRecording() async {
        _ = await Permissions.requestScreenRecordingPermission()
        await refresh()
    }

    func requestMicrophone() async {
        _ = await Permissions.requestMicrophonePermission(using: microphoneAuthorizationClient)
        refreshMicrophone()
    }

    func refreshMicrophone() {
        microphone = Permissions.microphoneAuthorizationStatus(using: microphoneAuthorizationClient)
    }

    func refreshCamera() {
        camera = Permissions.cameraAuthorizationStatus(using: cameraAuthorizationClient)
    }

    func requestCamera() async {
        _ = await Permissions.requestCameraPermission(using: cameraAuthorizationClient)
        refreshCamera()
    }
}
