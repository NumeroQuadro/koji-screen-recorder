import AVFoundation

struct MicrophoneCaptureDecision: Equatable {
    let capturesMicrophone: Bool
    let microphoneCaptureDeviceID: String?
}

enum MicrophoneCapturePolicy {
    static func shouldCaptureMicrophoneTrack(
        isMicrophoneEnabled: Bool,
        requestedCapture: Bool
    ) -> Bool {
        isMicrophoneEnabled && requestedCapture
    }

    static func shouldRequestPermission(
        isMicrophoneEnabled: Bool,
        permissionStatus: AVAuthorizationStatus
    ) -> Bool {
        guard isMicrophoneEnabled else { return false }
        return permissionStatus == .notDetermined
    }

    static func makeDecision(
        isMicrophoneEnabled: Bool,
        selectedDeviceID: String?,
        permissionStatus: AVAuthorizationStatus,
        microphoneCaptureSupported: Bool
    ) -> MicrophoneCaptureDecision {
        guard
            isMicrophoneEnabled,
            let selectedDeviceID,
            permissionStatus == .authorized,
            microphoneCaptureSupported
        else {
            return MicrophoneCaptureDecision(capturesMicrophone: false, microphoneCaptureDeviceID: nil)
        }

        return MicrophoneCaptureDecision(capturesMicrophone: true, microphoneCaptureDeviceID: selectedDeviceID)
    }

    static func shouldShowPermissionNotice(
        isMicrophoneEnabled: Bool,
        permissionStatus: AVAuthorizationStatus
    ) -> Bool {
        guard isMicrophoneEnabled else { return false }

        switch permissionStatus {
        case .authorized:
            return false
        case .notDetermined, .denied, .restricted:
            return true
        @unknown default:
            return true
        }
    }
}
