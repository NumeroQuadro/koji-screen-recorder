import AVFoundation
import Foundation

private let systemPreferredCameraKeyPath = "systemPreferredCamera"

@MainActor
protocol CameraDeviceDiscovery: AnyObject {
    func currentSnapshot() -> CameraDiscoverySnapshot
    func setUserPreferredCamera(deviceID: String)
    func startMonitoring(_ onChange: @escaping @MainActor () -> Void)
    func stopMonitoring()
}

@MainActor
final class AVFoundationCameraDeviceDiscovery: NSObject, CameraDeviceDiscovery {
    private var devicesByID: [String: AVCaptureDevice] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var isObservingSystemPreferredCamera = false
    private var onChange: (@MainActor () -> Void)?

    func currentSnapshot() -> CameraDiscoverySnapshot {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )

        var discoveredDevices: [String: AVCaptureDevice] = [:]
        for device in session.devices {
            discoveredDevices[device.uniqueID] = device
        }
        devicesByID = discoveredDevices

        let cameras = discoveredDevices.values
            .map(Self.cameraOption(for:))
            .sorted(by: Self.cameraSort)
        let cameraIDs = Set(cameras.map(\.id))
        let preferredID = AVCaptureDevice.systemPreferredCamera?.uniqueID

        return CameraDiscoverySnapshot(
            cameras: cameras,
            systemPreferredCameraID: preferredID.flatMap { cameraIDs.contains($0) ? $0 : nil }
        )
    }

    func setUserPreferredCamera(deviceID: String) {
        guard let device = devicesByID[deviceID] else { return }
        AVCaptureDevice.userPreferredCamera = device
    }

    func startMonitoring(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard notificationObservers.isEmpty, !isObservingSystemPreferredCamera else { return }

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
        ]
        notificationObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onChange?()
                }
            }
        }

        AVCaptureDevice.self.addObserver(
            self,
            forKeyPath: systemPreferredCameraKeyPath,
            options: [.new],
            context: nil
        )
        isObservingSystemPreferredCamera = true
    }

    func stopMonitoring() {
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()

        if isObservingSystemPreferredCamera {
            AVCaptureDevice.self.removeObserver(
                self,
                forKeyPath: systemPreferredCameraKeyPath
            )
            isObservingSystemPreferredCamera = false
        }

        onChange = nil
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == systemPreferredCameraKeyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        Task { @MainActor [weak self] in
            self?.onChange?()
        }
    }

    deinit {
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }

        if isObservingSystemPreferredCamera {
            AVCaptureDevice.self.removeObserver(
                self,
                forKeyPath: systemPreferredCameraKeyPath
            )
        }
    }

    private static func cameraOption(for device: AVCaptureDevice) -> CameraOption {
        CameraOption(
            id: device.uniqueID,
            name: device.localizedName,
            kind: cameraKind(for: device)
        )
    }

    private static func cameraKind(for device: AVCaptureDevice) -> CameraKind {
        if device.isContinuityCamera {
            return .continuity
        }

        if device.deviceType == .builtInWideAngleCamera {
            return .builtIn
        }

        return .external
    }

    private static func cameraSort(_ lhs: CameraOption, _ rhs: CameraOption) -> Bool {
        if lhs.kind.sortOrder != rhs.kind.sortOrder {
            return lhs.kind.sortOrder < rhs.kind.sortOrder
        }

        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.id < rhs.id
    }
}
