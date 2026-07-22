import CoreAudio
import Foundation

struct MicrophoneDiscoverySnapshot: Equatable, Sendable {
    let microphones: [MicrophoneOption]
    let defaultMicrophoneID: String?
}

@MainActor
protocol MicrophoneDeviceDiscovery: AnyObject {
    func currentSnapshot() throws -> MicrophoneDiscoverySnapshot
    func startMonitoring(_ onChange: @escaping @MainActor () -> Void)
    func stopMonitoring()
}

@MainActor
final class CoreAudioMicrophoneDeviceDiscovery: MicrophoneDeviceDiscovery {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private var onChange: (@MainActor () -> Void)?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var isMonitoringDevices = false
    private var isMonitoringDefaultInput = false

    func currentSnapshot() throws -> MicrophoneDiscoverySnapshot {
        let microphones = try Self.deviceIDs()
            .filter(Self.hasInputStreams)
            .compactMap { deviceID -> MicrophoneOption? in
                guard
                    let uid = try? Self.stringProperty(
                        objectID: deviceID,
                        selector: kAudioDevicePropertyDeviceUID
                    ),
                    let name = try? Self.stringProperty(
                        objectID: deviceID,
                        selector: kAudioObjectPropertyName
                    )
                else {
                    return nil
                }

                return MicrophoneOption(id: uid, name: name)
            }
            .sorted { lhs, rhs in
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                return lhs.id < rhs.id
            }

        let microphoneIDs = Set(microphones.map(\.id))
        let defaultMicrophoneID = try Self.defaultInputDeviceUID()

        return MicrophoneDiscoverySnapshot(
            microphones: microphones,
            defaultMicrophoneID: defaultMicrophoneID.flatMap {
                microphoneIDs.contains($0) ? $0 : nil
            }
        )
    }

    func startMonitoring(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard listenerBlock == nil else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.onChange?()
            }
        }
        listenerBlock = listener

        var devicesAddress = Self.devicesAddress
        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            Self.systemObject,
            &devicesAddress,
            .main,
            listener
        )
        isMonitoringDevices = devicesStatus == noErr
        if devicesStatus != noErr {
            print("Failed to monitor audio-device changes: OSStatus \(devicesStatus)")
        }

        var defaultInputAddress = Self.defaultInputAddress
        let defaultInputStatus = AudioObjectAddPropertyListenerBlock(
            Self.systemObject,
            &defaultInputAddress,
            .main,
            listener
        )
        isMonitoringDefaultInput = defaultInputStatus == noErr
        if defaultInputStatus != noErr {
            print("Failed to monitor default microphone changes: OSStatus \(defaultInputStatus)")
        }

        if !isMonitoringDevices, !isMonitoringDefaultInput {
            listenerBlock = nil
        }
    }

    func stopMonitoring() {
        guard let listenerBlock else {
            onChange = nil
            return
        }

        if isMonitoringDevices {
            var devicesAddress = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(
                Self.systemObject,
                &devicesAddress,
                .main,
                listenerBlock
            )
        }

        if isMonitoringDefaultInput {
            var defaultInputAddress = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                Self.systemObject,
                &defaultInputAddress,
                .main,
                listenerBlock
            )
        }

        isMonitoringDevices = false
        isMonitoringDefaultInput = false
        self.listenerBlock = nil
        onChange = nil
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func deviceIDs() throws -> [AudioDeviceID] {
        var address = devicesAddress
        var dataSize: UInt32 = 0
        try requireSuccess(
            AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize),
            operation: "read audio-device list size"
        )

        guard dataSize > 0 else { return [] }

        var devices = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        )
        let status = devices.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        try requireSuccess(status, operation: "read audio-device list")
        return devices
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize >= UInt32(MemoryLayout<AudioStreamID>.stride)
    }

    private static func defaultInputDeviceUID() throws -> String? {
        var address = defaultInputAddress
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.stride)
        try requireSuccess(
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                &dataSize,
                &deviceID
            ),
            operation: "read default microphone"
        )

        guard deviceID != kAudioObjectUnknown else { return nil }
        return try stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)
        try requireSuccess(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                &value
            ),
            operation: "read audio-device string property"
        )

        guard let value else {
            throw CoreAudioMicrophoneDiscoveryError.missingProperty(selector)
        }
        return value.takeRetainedValue() as String
    }

    private static func requireSuccess(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioMicrophoneDiscoveryError.operationFailed(operation, status)
        }
    }
}

private enum CoreAudioMicrophoneDiscoveryError: LocalizedError {
    case operationFailed(String, OSStatus)
    case missingProperty(AudioObjectPropertySelector)

    var errorDescription: String? {
        switch self {
        case let .operationFailed(operation, status):
            "Core Audio could not \(operation) (OSStatus \(status))."
        case let .missingProperty(selector):
            "Core Audio returned no value for property \(selector)."
        }
    }
}
