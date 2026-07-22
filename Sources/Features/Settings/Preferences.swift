import AppKit
import AVFoundation
import Foundation
import Observation
import ServiceManagement

struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiersRawValue: UInt
    var key: String?

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String? = nil) {
        self.keyCode = keyCode
        self.modifiersRawValue = modifiers.intersection(KeyCombo.relevantModifiers).rawValue
        self.key = key
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    func matches(event: NSEvent) -> Bool {
        let eventModifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        return event.keyCode == keyCode && eventModifiers == modifiers
    }

    var displayString: String {
        var parts: [String] = []

        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }

        parts.append(keyDisplayString)
        return parts.joined()
    }

    private var keyDisplayString: String {
        if let key, !key.isEmpty {
            return key.uppercased()
        }

        return switch keyCode {
        case 36: "⏎"
        case 48: "⇥"
        case 49: "Space"
        case 51: "⌫"
        case 53: "⎋"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "Key \(keyCode)"
        }
    }

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
}

@MainActor
@Observable
final class Preferences {
    struct MicrophonePreferenceState: Equatable {
        let isEnabled: Bool
        let selectedDeviceID: String?

        var isCaptureEnabled: Bool {
            isEnabled && selectedDeviceID != nil
        }
    }

    struct RecordingOutputSettings {
        let width: Int
        let height: Int
        let videoBitRate: Int
        let audioBitRate: Int
    }

    enum VideoCodec: String, CaseIterable, Identifiable, Codable {
        case h264
        case hevc

        var id: String { rawValue }

        var title: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            }
        }

        var avVideoCodecType: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc: .hevc
            }
        }
    }

    enum ContainerFormat: String, CaseIterable, Identifiable, Codable {
        case mov
        case mp4

        var id: String { rawValue }

        var fileType: AVFileType {
            switch self {
            case .mov: .mov
            case .mp4: .mp4
            }
        }

        var fileExtension: String {
            rawValue
        }
    }

    enum FrameRate: Int, CaseIterable, Identifiable, Codable {
        case fps30 = 30
        case fps60 = 60

        var id: Int { rawValue }
    }

    enum RecordingQuality: String, CaseIterable, Identifiable, Codable {
        case meeting
        case balanced
        case high

        var id: String { rawValue }

        var title: String {
            switch self {
            case .meeting: "Meeting"
            case .balanced: "Balanced"
            case .high: "High"
            }
        }

        var summary: String {
            switch self {
            case .meeting:
                "Smallest files. Caps output near 1080p and uses the lowest bitrate."
            case .balanced:
                "Recommended. Caps output near 1440p with a moderate bitrate."
            case .high:
                "Best quality. Keeps native resolution with the highest bitrate."
            }
        }

        func outputSettings(
            captureSize: (width: Int, height: Int),
            frameRate: FrameRate,
            codec: VideoCodec
        ) -> RecordingOutputSettings {
            let scaledSize = scaledCaptureSize(from: captureSize)
            let pixelCount = Double(scaledSize.width * scaledSize.height)
            let referencePixelCount = Double(1920 * 1080)
            let resolutionScale = max(0.75, sqrt(pixelCount / referencePixelCount))
            let frameRateScale = max(1.0, sqrt(Double(frameRate.rawValue) / 30.0))
            let codecScale = codec == .hevc ? 0.75 : 1.0
            let targetVideoBitRate = Int(
                (baseVideoBitRate * resolutionScale * frameRateScale * codecScale).rounded()
            )

            return RecordingOutputSettings(
                width: scaledSize.width,
                height: scaledSize.height,
                videoBitRate: max(minimumVideoBitRate, targetVideoBitRate),
                audioBitRate: audioBitRate
            )
        }

        private var baseVideoBitRate: Double {
            switch self {
            case .meeting: 4_000_000
            case .balanced: 6_000_000
            case .high: 10_000_000
            }
        }

        private var minimumVideoBitRate: Int {
            switch self {
            case .meeting: 2_500_000
            case .balanced: 4_000_000
            case .high: 6_000_000
            }
        }

        private var audioBitRate: Int {
            switch self {
            case .meeting: 96_000
            case .balanced: 128_000
            case .high: 192_000
            }
        }

        private var maxLongEdge: Int? {
            switch self {
            case .meeting: 1_920
            case .balanced: 2_560
            case .high: nil
            }
        }

        private func scaledCaptureSize(from captureSize: (width: Int, height: Int)) -> (width: Int, height: Int) {
            guard let maxLongEdge else {
                return evenDimensions(for: captureSize)
            }

            let longEdge = max(captureSize.width, captureSize.height)
            guard longEdge > maxLongEdge else {
                return evenDimensions(for: captureSize)
            }

            let scale = Double(maxLongEdge) / Double(longEdge)
            return evenDimensions(
                for: (
                    width: Int((Double(captureSize.width) * scale).rounded()),
                    height: Int((Double(captureSize.height) * scale).rounded())
                )
            )
        }

        private func evenDimensions(for size: (width: Int, height: Int)) -> (width: Int, height: Int) {
            (width: evenDimension(size.width), height: evenDimension(size.height))
        }

        private func evenDimension(_ value: Int) -> Int {
            let clampedValue = max(2, value)
            if clampedValue.isMultiple(of: 2) {
                return clampedValue
            }

            return max(2, clampedValue - 1)
        }
    }

    private enum Keys {
        static let outputDirectory = "Koji.Preferences.outputDirectory"
        static let videoCodec = "Koji.Preferences.videoCodec"
        static let containerFormat = "Koji.Preferences.containerFormat"
        static let frameRate = "Koji.Preferences.frameRate"
        static let recordingQuality = "Koji.Preferences.recordingQuality"
        static let showCursor = "Koji.Preferences.showCursor"
        static let launchAtLogin = "Koji.Preferences.launchAtLogin"
        static let selectedDisplayID = "Koji.Preferences.selectedDisplayID"
        static let selectedMicDeviceID = "Koji.Preferences.selectedMicDeviceID"
        static let micEnabled = "Koji.Preferences.micEnabled"
        static let facecamEnabled = "Koji.Preferences.facecamEnabled"
        static let cameraSelectionMode = "Koji.Preferences.cameraSelectionMode"
        static let selectedCameraDeviceID = "Koji.Preferences.selectedCameraDeviceID"
        static let facecamPlacement = "Koji.Preferences.facecamPlacement"
        static let globalHotkey = "Koji.Preferences.globalHotkey"
    }

    @ObservationIgnored private let defaults: UserDefaults

    nonisolated static func microphonePreferenceState(
        from defaults: UserDefaults = .standard
    ) -> MicrophonePreferenceState {
        let isEnabled: Bool
        if defaults.object(forKey: Keys.micEnabled) != nil {
            isEnabled = defaults.bool(forKey: Keys.micEnabled)
        } else {
            isEnabled = true
        }

        return MicrophonePreferenceState(
            isEnabled: isEnabled,
            selectedDeviceID: defaults.string(forKey: Keys.selectedMicDeviceID)
        )
    }

    var outputDirectory: URL {
        didSet { defaults.set(outputDirectory.path, forKey: Keys.outputDirectory) }
    }

    var videoCodec: VideoCodec {
        didSet { defaults.set(videoCodec.rawValue, forKey: Keys.videoCodec) }
    }

    var containerFormat: ContainerFormat {
        didSet { defaults.set(containerFormat.rawValue, forKey: Keys.containerFormat) }
    }

    var frameRate: FrameRate {
        didSet { defaults.set(frameRate.rawValue, forKey: Keys.frameRate) }
    }

    var recordingQuality: RecordingQuality {
        didSet { defaults.set(recordingQuality.rawValue, forKey: Keys.recordingQuality) }
    }

    var showCursor: Bool {
        didSet { defaults.set(showCursor, forKey: Keys.showCursor) }
    }

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            Task { [launchAtLogin] in
                await Self.applyLaunchAtLoginSetting(enabled: launchAtLogin)
            }
        }
    }

    var selectedDisplayID: CGDirectDisplayID? {
        didSet {
            if let selectedDisplayID {
                defaults.set(Int(selectedDisplayID), forKey: Keys.selectedDisplayID)
            } else {
                defaults.removeObject(forKey: Keys.selectedDisplayID)
            }
        }
    }

    var selectedMicDeviceID: String? {
        didSet {
            if let selectedMicDeviceID {
                defaults.set(selectedMicDeviceID, forKey: Keys.selectedMicDeviceID)
            } else {
                defaults.removeObject(forKey: Keys.selectedMicDeviceID)
                if micEnabled {
                    micEnabled = false
                }
            }
        }
    }

    var micEnabled: Bool {
        didSet {
            if micEnabled, selectedMicDeviceID == nil {
                micEnabled = false
                return
            }
            defaults.set(micEnabled, forKey: Keys.micEnabled)
        }
    }

    var includeMicrophoneInRecordings: Bool {
        get { micEnabled }
        set { micEnabled = newValue }
    }

    var isFacecamEnabled: Bool {
        didSet { defaults.set(isFacecamEnabled, forKey: Keys.facecamEnabled) }
    }

    var cameraSelection: CameraSelection {
        didSet {
            switch cameraSelection {
            case .automatic:
                defaults.set("automatic", forKey: Keys.cameraSelectionMode)
                defaults.removeObject(forKey: Keys.selectedCameraDeviceID)
            case let .manual(deviceID):
                defaults.set("manual", forKey: Keys.cameraSelectionMode)
                defaults.set(deviceID, forKey: Keys.selectedCameraDeviceID)
            }
        }
    }

    var facecamPlacement: FacecamPlacement {
        didSet { saveFacecamPlacement(facecamPlacement) }
    }

    var globalHotkey: KeyCombo? {
        didSet { saveHotkey(globalHotkey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        outputDirectory = Self.defaultOutputDirectory

        if let raw = defaults.string(forKey: Keys.videoCodec), let codec = VideoCodec(rawValue: raw) {
            videoCodec = codec
        } else {
            videoCodec = .h264
        }

        if let raw = defaults.string(forKey: Keys.containerFormat), let format = ContainerFormat(rawValue: raw) {
            containerFormat = format
        } else {
            containerFormat = .mov
        }

        let storedFrameRate = defaults.integer(forKey: Keys.frameRate)
        frameRate = FrameRate(rawValue: storedFrameRate) ?? .fps30

        if let raw = defaults.string(forKey: Keys.recordingQuality), let quality = RecordingQuality(rawValue: raw) {
            recordingQuality = quality
        } else {
            recordingQuality = .balanced
        }

        if defaults.object(forKey: Keys.showCursor) != nil {
            showCursor = defaults.bool(forKey: Keys.showCursor)
        } else {
            showCursor = true
        }

        let serviceEnabled = SMAppService.mainApp.status == .enabled
        if defaults.object(forKey: Keys.launchAtLogin) != nil {
            launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        } else {
            launchAtLogin = serviceEnabled
        }

        if let path = defaults.string(forKey: Keys.outputDirectory) {
            outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }

        if defaults.object(forKey: Keys.selectedDisplayID) != nil {
            let rawID = defaults.integer(forKey: Keys.selectedDisplayID)
            if rawID > 0 {
                selectedDisplayID = CGDirectDisplayID(rawID)
            } else {
                selectedDisplayID = nil
            }
        } else {
            selectedDisplayID = nil
        }

        selectedMicDeviceID = defaults.string(forKey: Keys.selectedMicDeviceID)

        if defaults.object(forKey: Keys.micEnabled) != nil {
            micEnabled = defaults.bool(forKey: Keys.micEnabled)
        } else {
            micEnabled = true
        }

        if defaults.object(forKey: Keys.facecamEnabled) != nil {
            isFacecamEnabled = defaults.bool(forKey: Keys.facecamEnabled)
        } else {
            isFacecamEnabled = false
        }

        if defaults.string(forKey: Keys.cameraSelectionMode) == "manual",
           let deviceID = defaults.string(forKey: Keys.selectedCameraDeviceID),
           !deviceID.isEmpty {
            cameraSelection = .manual(deviceID: deviceID)
        } else {
            cameraSelection = .automatic
        }

        facecamPlacement = Self.loadFacecamPlacement(from: defaults) ?? .default

        globalHotkey = Self.loadHotkey(from: defaults)
        if globalHotkey == nil {
            globalHotkey = Self.defaultHotkey
        }
    }

    func ensureOutputDirectoryExists() {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create output directory: \(error)")
        }
    }

    private func saveHotkey(_ hotkey: KeyCombo?) {
        guard let hotkey else {
            defaults.removeObject(forKey: Keys.globalHotkey)
            return
        }

        do {
            let data = try JSONEncoder().encode(hotkey)
            defaults.set(data, forKey: Keys.globalHotkey)
        } catch {
            print("Failed to save hotkey: \(error)")
        }
    }

    private func saveFacecamPlacement(_ placement: FacecamPlacement) {
        do {
            defaults.set(try JSONEncoder().encode(placement.sanitized()), forKey: Keys.facecamPlacement)
        } catch {
            print("Failed to save facecam placement: \(error)")
        }
    }

    private static func loadFacecamPlacement(from defaults: UserDefaults) -> FacecamPlacement? {
        guard let data = defaults.data(forKey: Keys.facecamPlacement) else { return nil }
        do {
            return try JSONDecoder().decode(FacecamPlacement.self, from: data).sanitized()
        } catch {
            print("Failed to load facecam placement: \(error)")
            return nil
        }
    }

    private static func loadHotkey(from defaults: UserDefaults) -> KeyCombo? {
        guard let data = defaults.data(forKey: Keys.globalHotkey) else { return nil }
        do {
            return try JSONDecoder().decode(KeyCombo.self, from: data)
        } catch {
            print("Failed to load hotkey: \(error)")
            return nil
        }
    }

    private static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Koji", isDirectory: true)
    }

    private static var defaultHotkey: KeyCombo {
        KeyCombo(keyCode: 15, modifiers: [.control, .command], key: "R")
    }

    private static func applyLaunchAtLoginSetting(enabled: Bool) async {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login update failed: \(error)")
        }
    }
}
