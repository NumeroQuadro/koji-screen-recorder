import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Observation
import OSLog
import ScreenCaptureKit

enum RecordingCoordinatorState: Equatable {
    case idle
    case preparing
    case recording
    case stopping

    var isBusy: Bool {
        self == .preparing || self == .stopping
    }
}

enum RecordingCoordinatorError: LocalizedError {
    case screenRecordingPermissionDenied
    case noDisplayAvailable
    case insufficientDiskSpace
    case firstVideoFrameTimedOut

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            "Screen Recording access is required. Enable Koji in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .noDisplayAvailable:
            "The selected capture source is unavailable. Choose another display, window, or application."
        case .insufficientDiskSpace:
            "There is not enough free disk space to start recording."
        case .firstVideoFrameTimedOut:
            "Koji did not receive a usable screen frame within 5 seconds. Reopen Screen Recording access or choose another source, then try again."
        }
    }
}

@MainActor
@Observable
final class RecordingCoordinator {
    private static let captureSourceDefaultsKey = "Koji.CaptureSource"
    private static let firstVideoFrameTimeout: TimeInterval = 5
    private static let startupLogger = Logger(
        subsystem: "com.koji.screenrecorder",
        category: "RecordingStartup"
    )
    private static let performanceLogger = Logger(
        subsystem: "com.koji.screenrecorder",
        category: "RecordingPerformance"
    )
    private static let diagnosticsInterval: Duration = .seconds(60)

    var state: RecordingCoordinatorState = .idle
    var errorMessage: String?
    var warningMessage: String?
    var facecamWarningMessage: String?
    var recoveredFiles: [URL] = []
    var orphanedTempFiles: [URL] = []
    var discardedArtifactCount: Int = 0
    var isMicrophoneEnabled: Bool {
        didSet {
            preferences.micEnabled = isMicrophoneEnabled
        }
    }
    var isMicrophoneCaptureActive: Bool = false
    var displaySources: [CaptureSourceOption] = []
    var applicationSources: [CaptureSourceOption] = []
    var windowSources: [CaptureSourceOption] = []
    var selectedCaptureSourceToken: String {
        didSet {
            UserDefaults.standard.set(selectedCaptureSourceToken, forKey: Self.captureSourceDefaultsKey)
            if let token = CaptureSourceToken(rawValue: selectedCaptureSourceToken) {
                if case let .display(displayID) = token {
                    preferences.selectedDisplayID = displayID
                }
            }
        }
    }

    var microphoneOptions: [MicrophoneOption] = []
    var selectedMicrophoneID: String {
        didSet {
            if selectedMicrophoneID == MicrophoneOption.noneID {
                isMicrophoneEnabled = false
                preferences.selectedMicDeviceID = nil
                audioMixer.setMicrophoneEnabled(false)
            } else {
                preferences.selectedMicDeviceID = selectedMicrophoneID
            }
        }
    }

    private let preferences: Preferences
    private let notificationManager: NotificationManager
    private let captureEngine: CaptureEngine
    private let recordingState: RecordingState
    private let permissionsState: PermissionsState
    private let audioMixer: AudioMixer
    private let microphoneDiscovery: any MicrophoneDeviceDiscovery
    private let recordingOutputValidator: any RecordingOutputValidating
    private let captureTargetResolver: CaptureTargetResolver
    private let cameraAccessController: CameraAccessController?
    private let cameraFrameProvider: (any CameraFrameProviding)?
    private let facecamPlacementStore: FacecamPlacementStore?

    private var recordingPipeline: RecordingPipeline?
    private var captureConfiguration: CaptureConfiguration = .init()
    private var fileSizeTask: Task<Void, Never>?
    private var diskSpaceTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var activeFacecamCompositor: FacecamVideoCompositor?
    private var isFinalizing: Bool = false
    private var isFacecamRecordingConsumerActive = false
    private var isFacecamIntentionallyDisabledDuringRecording = false

    private let lowDiskWarningBytes: Int64 = 1_000_000_000
    private let lowDiskStopBytes: Int64 = 500_000_000

    init(
        recordingState: RecordingState,
        permissionsState: PermissionsState,
        preferences: Preferences,
        notificationManager: NotificationManager,
        microphoneDiscovery: (any MicrophoneDeviceDiscovery)? = nil,
        recordingOutputValidator: any RecordingOutputValidating = RecordingOutputValidator(),
        captureTargetResolver: CaptureTargetResolver = CaptureTargetResolver(),
        cameraAccessController: CameraAccessController? = nil,
        cameraFrameProvider: (any CameraFrameProviding)? = nil,
        facecamPlacementStore: FacecamPlacementStore? = nil
    ) {
        self.recordingState = recordingState
        self.permissionsState = permissionsState
        self.preferences = preferences
        self.notificationManager = notificationManager
        self.microphoneDiscovery = microphoneDiscovery ?? CoreAudioMicrophoneDeviceDiscovery()
        self.recordingOutputValidator = recordingOutputValidator
        self.captureTargetResolver = captureTargetResolver
        self.cameraAccessController = cameraAccessController
        self.cameraFrameProvider = cameraFrameProvider
        self.facecamPlacementStore = facecamPlacementStore
        captureEngine = CaptureEngine()
        audioMixer = AudioMixer()
        selectedCaptureSourceToken = UserDefaults.standard.string(forKey: Self.captureSourceDefaultsKey) ?? ""
        selectedMicrophoneID = preferences.selectedMicDeviceID ?? MicrophoneOption.noneID
        isMicrophoneEnabled = preferences.micEnabled

        self.microphoneDiscovery.startMonitoring { [weak self] in
            Task { [weak self] in
                await self?.refreshMicrophones()
            }
        }

        observePreferences()
    }

    @MainActor
    deinit {
        microphoneDiscovery.stopMonitoring()
    }

    func toggleRecording() async {
        switch state {
        case .idle:
            do { try await startRecording() } catch { handleError(error, userMessage: "Failed to start recording.") }
        case .recording:
            do { try await stopRecording() } catch { handleError(error, userMessage: "Failed to stop recording.") }
        case .preparing, .stopping:
            break
        }
    }

    func toggleMicrophoneEnabled() async {
        await setMicrophoneEnabled(!isMicrophoneEnabled)
    }

    func setMicrophoneEnabled(_ enabled: Bool) async {
        guard !state.isBusy else { return }
        guard selectedMicrophoneDeviceID != nil else { return }

        if !enabled {
            isMicrophoneEnabled = false
            audioMixer.setMicrophoneEnabled(false)
            return
        }

        isMicrophoneEnabled = true
        permissionsState.refreshMicrophone()
        if permissionsState.microphone == .notDetermined {
            await permissionsState.requestMicrophone()
        }

        guard permissionsState.microphone == .authorized else {
            if warningMessage == nil {
                switch permissionsState.microphone {
                case .denied:
                    warningMessage = "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
                case .restricted:
                    warningMessage = "Microphone access is restricted on this Mac."
                case .notDetermined, .authorized:
                    break
                @unknown default:
                    warningMessage = "Microphone access is unavailable."
                }
            }
            audioMixer.setMicrophoneEnabled(false)
            return
        }

        audioMixer.setMicrophoneEnabled(isMicrophoneCaptureActive)
    }

    func setFacecamEnabled(_ isEnabled: Bool) async {
        let isRecordingActive = state == .preparing || state == .recording
        isFacecamIntentionallyDisabledDuringRecording = !isEnabled && isRecordingActive
        facecamWarningMessage = nil
        await cameraAccessController?.setFacecamEnabled(isEnabled)
    }

    var selectedCaptureSourceTitle: String {
        allCaptureSources.first(where: { $0.id == selectedCaptureSourceToken })?.title ?? "Primary Display"
    }

    var selectedMicrophoneName: String {
        microphoneOptions.first(where: { $0.id == selectedMicrophoneID })?.name ?? MicrophoneOption.none.name
    }

    var microphoneAuthorizationStatus: AVAuthorizationStatus {
        permissionsState.microphone
    }

    var canToggleMicrophone: Bool {
        guard selectedMicrophoneDeviceID != nil else { return false }
        return !state.isBusy
    }

    func refreshCaptureSources() async {
        await permissionsState.refresh()
        guard permissionsState.screenRecording == .granted else { return }

        do {
            let content = try await captureEngine.availableContent()

            let primaryDisplayID = CaptureTargetResolver.primaryDisplayID(from: content.displays)
            let primaryDisplay = primaryDisplayID
                .flatMap { displayID in content.displays.first(where: { $0.displayID == displayID }) }
                ?? content.displays.first
            let preferredDisplay = preferences.selectedDisplayID
                .flatMap { displayID in content.displays.first(where: { $0.displayID == displayID }) }
            let fallbackDisplay = preferredDisplay ?? primaryDisplay
            let displayOptions = content.displays.map { display in
                CaptureSourceOption(
                    token: .display(display.displayID),
                    title: displayName(for: display.displayID),
                    subtitle: displayResolutionLabel(for: display)
                )
            }

            let appOptions = content.applications
                .sorted(by: { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending })
                .map { app in
                    CaptureSourceOption(token: .application(bundleIdentifier: app.bundleIdentifier), title: app.applicationName, subtitle: nil)
                }

            let windowOptions = content.windows
                .filter { $0.isOnScreen }
                .filter { $0.windowLayer == 0 }
                .sorted { lhs, rhs in
                    let lhsApp = lhs.owningApplication?.applicationName ?? ""
                    let rhsApp = rhs.owningApplication?.applicationName ?? ""
                    let appCompare = lhsApp.localizedCaseInsensitiveCompare(rhsApp)
                    if appCompare != .orderedSame {
                        return appCompare == .orderedAscending
                    }
                    return (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending
                }
                .map { window in
                    let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let windowTitle = (title?.isEmpty == false) ? title! : "Untitled Window"
                    let subtitle = window.owningApplication?.applicationName
                    return CaptureSourceOption(token: .window(window.windowID), title: windowTitle, subtitle: subtitle)
                }

            displaySources = displayOptions
            applicationSources = appOptions
            windowSources = windowOptions

            let hasSelection = allCaptureSources.contains(where: { $0.id == selectedCaptureSourceToken })
            if !hasSelection, let fallbackDisplay {
                selectedCaptureSourceToken = CaptureSourceToken.display(fallbackDisplay.displayID).rawValue
                preferences.selectedDisplayID = fallbackDisplay.displayID
            }
        } catch {
            print("Refresh capture sources failed: \(error)")
        }
    }

    func refreshMicrophones() async {
        let snapshot: MicrophoneDiscoverySnapshot
        do {
            snapshot = try microphoneDiscovery.currentSnapshot()
        } catch {
            print("Refresh microphones failed: \(error.localizedDescription)")
            if warningMessage == nil {
                warningMessage = "Unable to refresh available microphones."
            }
            return
        }

        microphoneOptions = [MicrophoneOption.none] + snapshot.microphones

        if let preferredID = preferences.selectedMicDeviceID, microphoneOptions.contains(where: { $0.id == preferredID }) {
            if selectedMicrophoneID != preferredID {
                selectedMicrophoneID = preferredID
            }
            return
        }

        if preferences.micEnabled, let defaultMicrophoneID = snapshot.defaultMicrophoneID {
            selectedMicrophoneID = defaultMicrophoneID
            preferences.selectedMicDeviceID = defaultMicrophoneID
            return
        }

        selectedMicrophoneID = MicrophoneOption.noneID
        preferences.selectedMicDeviceID = nil
        preferences.micEnabled = false
    }

    func startRecording() async throws {
        guard state == .idle else { return }
        state = .preparing
        errorMessage = nil
        warningMessage = nil
        facecamWarningMessage = nil
        isFacecamIntentionallyDisabledDuringRecording = false

        await permissionsState.refresh()
        guard permissionsState.screenRecording == .granted else {
            state = .idle
            throw RecordingCoordinatorError.screenRecordingPermissionDenied
        }

        let diskSpace = availableDiskSpaceBytes(at: preferences.outputDirectory)
        if let diskSpace, diskSpace < lowDiskStopBytes {
            state = .idle
            errorMessage = "Not enough free disk space to start recording."
            notificationManager.postWarning(title: "Low disk space", message: "Free space is below 500MB.")
            throw RecordingCoordinatorError.insufficientDiskSpace
        } else if let diskSpace, diskSpace < lowDiskWarningBytes {
            warningMessage = "Low disk space: \(ByteCountFormatter.string(fromByteCount: diskSpace, countStyle: .file)) free."
        }

        recordingState.elapsedTime = 0
        recordingState.currentFile = nil
        recordingState.currentFileSizeBytes = 0
        recordingState.lastSavedFile = nil

        captureConfiguration.frameRate = preferences.frameRate == .fps60 ? .fps60 : .fps30
        captureConfiguration.showsCursor = preferences.showCursor

        let content = try await captureEngine.availableContent()

        guard let resolvedTarget = captureTargetResolver.resolve(
            selectedToken: CaptureSourceToken(rawValue: selectedCaptureSourceToken),
            preferredDisplayID: preferences.selectedDisplayID,
            content: content
        ) else {
            state = .idle
            throw RecordingCoordinatorError.noDisplayAvailable
        }

        let filter = resolvedTarget.filter
        let captureSize = (
            width: resolvedTarget.pixelSize.width,
            height: resolvedTarget.pixelSize.height
        )
        let outputSettings = preferences.recordingQuality.outputSettings(
            captureSize: captureSize,
            frameRate: preferences.frameRate,
            codec: preferences.videoCodec
        )
        let microphoneDecision = await resolveMicrophoneCaptureDecision()
        isMicrophoneCaptureActive = microphoneDecision.capturesMicrophone
        captureConfiguration.capturesMicrophone = microphoneDecision.capturesMicrophone
        captureConfiguration.microphoneCaptureDeviceID = microphoneDecision.microphoneCaptureDeviceID
        let streamConfiguration = captureConfiguration.makeStreamConfiguration(
            width: outputSettings.width,
            height: outputSettings.height,
            scalesToFit: resolvedTarget.scalesToFit
        )

        let videoCompositor: (any RecordingVideoCompositing)?
        if
            cameraAccessController?.canUseFacecam == true,
            let cameraFrameProvider,
            let facecamPlacementStore,
            let displayGeometry = resolvedTarget.selectedDisplayGeometry
        {
            let facecamCompositor = FacecamVideoCompositor(
                cameraFrameProvider: cameraFrameProvider,
                placementStore: facecamPlacementStore,
                displayGeometry: displayGeometry,
                outputPixelSize: CapturePixelSize(
                    width: outputSettings.width,
                    height: outputSettings.height
                ),
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleFacecamCompositorEvent(event)
                    }
                }
            )
            videoCompositor = facecamCompositor
        } else {
            videoCompositor = nil
        }

        let recordingPipeline = try RecordingPipeline(
            width: outputSettings.width,
            height: outputSettings.height,
            includesMicrophoneTrack: microphoneDecision.capturesMicrophone,
            outputDirectory: preferences.outputDirectory,
            fileType: preferences.containerFormat.fileType,
            fileExtension: preferences.containerFormat.fileExtension,
            videoCodec: preferences.videoCodec.avVideoCodecType,
            expectedFrameRate: preferences.frameRate.rawValue,
            videoBitRate: outputSettings.videoBitRate,
            audioBitRate: outputSettings.audioBitRate,
            videoCompositor: videoCompositor,
            outputValidator: recordingOutputValidator
        )
        try recordingPipeline.startWriting()
        self.recordingPipeline = recordingPipeline
        activeFacecamCompositor = videoCompositor as? FacecamVideoCompositor
        recordingState.currentFile = recordingPipeline.temporaryURL

        fileSizeTask?.cancel()
        fileSizeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.recordingState.isRecording || self.state == .preparing {
                guard let url = self.recordingState.currentFile else { break }
                let fileSize = (try? RecordingArtifactPolicy.regularFileSize(at: url)) ?? 0
                self.recordingState.currentFileSizeBytes = fileSize
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let updateElapsed: (CMSampleBuffer) -> Void = { [weak self] sampleBuffer in
            guard let elapsed = recordingPipeline.elapsedTime(for: sampleBuffer) else { return }

            DispatchQueue.main.async { [weak self] in
                self?.recordingState.elapsedTime = elapsed
            }
        }

        let audioMixer = self.audioMixer
        let videoSink: any RecordingVideoFrameSink = recordingPipeline

        captureEngine.onVideoSampleBuffer = { sampleBuffer in
            videoSink.submitScreenFrame(sampleBuffer)
            updateElapsed(sampleBuffer)
        }

        captureEngine.onAudioSampleBuffer = { sampleBuffer in
            audioMixer.handleSystemAudio(sampleBuffer)
            updateElapsed(sampleBuffer)
        }

        captureEngine.onMicrophoneSampleBuffer = { sampleBuffer in
            audioMixer.handleMicrophoneAudio(sampleBuffer)
            updateElapsed(sampleBuffer)
        }

        audioMixer.onSystemAudio = { sampleBuffer in
            recordingPipeline.submitSystemAudio(sampleBuffer)
        }

        audioMixer.onMicrophoneAudio = { sampleBuffer in
            recordingPipeline.submitMicrophone(sampleBuffer)
        }

        audioMixer.setMicrophoneEnabled(microphoneDecision.capturesMicrophone)

        captureEngine.onStop = { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.handleStreamStopped(error: error)
            }
        }

        var captureStarted = false
        do {
            if videoCompositor != nil, let cameraAccessController {
                await cameraAccessController.setRecordingConsumerActive(true)
                isFacecamRecordingConsumerActive = true
            }
            try await captureEngine.startCapture(filter: filter, config: streamConfiguration)
            captureStarted = true

            let didAcceptFirstVideoFrame = await recordingPipeline.waitForFirstVideoFrame(
                timeout: Self.firstVideoFrameTimeout
            )
            guard didAcceptFirstVideoFrame else {
                let captureMetrics = await captureEngine.sampleMetrics()
                let ingestionMetrics = recordingPipeline.ingestionMetrics()
                let deliveryMetrics = recordingPipeline.deliveryMetrics()
                Self.startupLogger.error(
                    "First video frame timed out: screenCallbacks=\(captureMetrics.screenCallbackCount, privacy: .public) forwarded=\(captureMetrics.forwardedScreenFrameCount, privacy: .public) invalid=\(captureMetrics.invalidScreenSampleCount, privacy: .public) notReady=\(captureMetrics.dataNotReadyScreenSampleCount, privacy: .public) noImage=\(captureMetrics.missingImageBufferCount, privacy: .public) noStatus=\(captureMetrics.missingFrameStatusCount, privacy: .public) idle=\(captureMetrics.idleScreenFrameCount, privacy: .public) blank=\(captureMetrics.blankScreenFrameCount, privacy: .public) suspended=\(captureMetrics.suspendedScreenFrameCount, privacy: .public) started=\(captureMetrics.startedScreenFrameCount, privacy: .public) audioCallbacks=\(captureMetrics.systemAudioCallbackCount, privacy: .public) micCallbacks=\(captureMetrics.microphoneCallbackCount, privacy: .public) queuedVideo=\(ingestionMetrics.video.acceptedSampleCount, privacy: .public) droppedVideo=\(ingestionMetrics.video.droppedSampleCount, privacy: .public) appendedVideo=\(deliveryMetrics.appendedVideoFrameCount, privacy: .public) videoInputNotReady=\(deliveryMetrics.videoInputNotReadyCount, privacy: .public) videoAppendFailures=\(deliveryMetrics.videoAppendFailureCount, privacy: .public) appendedAudio=\(deliveryMetrics.appendedSystemAudioSampleCount, privacy: .public)"
                )
                throw RecordingCoordinatorError.firstVideoFrameTimedOut
            }
        } catch {
            if isFacecamRecordingConsumerActive {
                await cameraAccessController?.setRecordingConsumerActive(false)
                isFacecamRecordingConsumerActive = false
            }
            if captureStarted {
                try? await captureEngine.stopCapture()
            }
            let temporaryURL = recordingPipeline.temporaryURL
            let finalizedURL = try? await recordingPipeline.finishWriting()
            try? FileManager.default.removeItem(at: temporaryURL)
            if let finalizedURL {
                try? FileManager.default.removeItem(at: finalizedURL)
            }

            captureEngine.onVideoSampleBuffer = nil
            captureEngine.onAudioSampleBuffer = nil
            captureEngine.onMicrophoneSampleBuffer = nil
            captureEngine.onStop = nil
            audioMixer.onSystemAudio = nil
            audioMixer.onMicrophoneAudio = nil
            self.recordingPipeline = nil
            activeFacecamCompositor = nil
            fileSizeTask?.cancel()
            fileSizeTask = nil
            diagnosticsTask?.cancel()
            diagnosticsTask = nil
            isMicrophoneCaptureActive = false
            recordingState.currentFile = nil
            recordingState.currentFileSizeBytes = 0
            recordingState.isRecording = false
            state = .idle
            throw error
        }

        recordingState.isRecording = true
        state = .recording
        startDiagnosticsSampling()

        diskSpaceTask?.cancel()
        diskSpaceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.recordingState.isRecording {
                guard let diskSpace = self.availableDiskSpaceBytes(at: self.preferences.outputDirectory) else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }

                if diskSpace < self.lowDiskStopBytes {
                    self.errorMessage = "Recording stopped: low disk space."
                    self.notificationManager.postWarning(title: "Recording stopped", message: "Free space dropped below 500MB.")
                    await self.finalizeRecording(stopCapture: true, isPartial: true)
                    return
                }

                if diskSpace < self.lowDiskWarningBytes, self.warningMessage == nil {
                    self.warningMessage = "Low disk space: \(ByteCountFormatter.string(fromByteCount: diskSpace, countStyle: .file)) free."
                }

                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopRecording() async throws {
        await finalizeRecording(stopCapture: true, isPartial: false)
    }

    private var allCaptureSources: [CaptureSourceOption] {
        displaySources + applicationSources + windowSources
    }

    private var selectedMicrophoneDeviceID: String? {
        selectedMicrophoneID == MicrophoneOption.noneID ? nil : selectedMicrophoneID
    }

    private func resolveMicrophoneCaptureDecision() async -> MicrophoneCaptureDecision {
        let selectedDeviceID = selectedMicrophoneDeviceID
        let microphoneCaptureSupported: Bool

        if #available(macOS 15.0, *) {
            microphoneCaptureSupported = true
        } else {
            microphoneCaptureSupported = false
        }

        if microphoneCaptureSupported, isMicrophoneEnabled, selectedDeviceID != nil {
            permissionsState.refreshMicrophone()
            if permissionsState.microphone == .notDetermined {
                await permissionsState.requestMicrophone()
            }
        }

        return MicrophoneCapturePolicy.makeDecision(
            isMicrophoneEnabled: isMicrophoneEnabled,
            selectedDeviceID: selectedDeviceID,
            permissionStatus: permissionsState.microphone,
            microphoneCaptureSupported: microphoneCaptureSupported
        )
    }

    func recoverOrphanedRecordings() async {
        guard state == .idle else { return }

        recoveredFiles = []
        orphanedTempFiles = []
        discardedArtifactCount = 0

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: preferences.outputDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            for url in urls {
                guard let kind = RecordingArtifactPolicy.kind(for: url, in: preferences.outputDirectory) else {
                    continue
                }

                do {
                    let fileSize = try RecordingArtifactPolicy.regularFileSize(at: url)
                    if fileSize == 0 {
                        try FileManager.default.removeItem(at: url)
                        discardedArtifactCount += 1
                        continue
                    }

                    switch kind {
                    case let .temporaryRecording(finalURL):
                        try await recordingOutputValidator.validateRecording(at: url)
                        let destination = uniqueFileURL(for: finalURL)
                        try FileManager.default.moveItem(at: url, to: destination)
                        recoveredFiles.append(destination)
                        notificationManager.postWarning(title: "Recovered recording", message: destination.lastPathComponent)
                    case .crashSidecar:
                        orphanedTempFiles.append(url)
                    }
                } catch {
                    orphanedTempFiles.append(url)
                }
            }

            if discardedArtifactCount > 0 {
                let message = "Removed \(discardedArtifactCount) empty recording artifact(s) left by an interrupted recording."
                warningMessage = message
                notificationManager.postWarning(title: "Recording cleanup", message: message)
            }
        } catch {
            print("Failed to scan for orphaned recordings: \(error)")
        }
    }

    func deleteOrphanedRecording(_ url: URL) {
        guard RecordingArtifactPolicy.kind(for: url, in: preferences.outputDirectory) != nil else {
            errorMessage = "Koji refused to delete a file it did not create."
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
            orphanedTempFiles.removeAll(where: { $0 == url })
        } catch {
            errorMessage = "Failed to delete orphaned file."
            print("Delete orphaned file failed: \(error)")
        }
    }

    private func uniqueFileURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var candidate = url
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName)_Recovered_\(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }

        return candidate
    }

    private func availableDiskSpaceBytes(at directory: URL) -> Int64? {
        do {
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return important
            }
            if let available = values.volumeAvailableCapacity {
                return Int64(available)
            }
            return nil
        } catch {
            return nil
        }
    }

    private func handleStreamStopped(error: Error) async {
        guard state == .recording || state == .preparing else { return }
        guard state != .stopping else { return }

        await permissionsState.refresh()

        if permissionsState.screenRecording != .granted {
            if errorMessage == nil {
                errorMessage = "Recording stopped: Screen Recording permission was revoked."
            }
        } else {
            if let token = CaptureSourceToken(rawValue: selectedCaptureSourceToken) {
                do {
                    let content = try await captureEngine.availableContent()
                    switch token {
                    case let .display(displayID):
                        if !content.displays.contains(where: { $0.displayID == displayID }) {
                            if errorMessage == nil {
                                errorMessage = "Recording stopped: capture display disconnected."
                            }
                        }
                    case let .window(windowID):
                        if !content.windows.contains(where: { $0.windowID == windowID }) {
                            if errorMessage == nil {
                                errorMessage = "Recording stopped: capture window closed."
                            }
                        }
                    case let .application(bundleIdentifier):
                        if !content.applications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                            if errorMessage == nil {
                                errorMessage = "Recording stopped: capture app quit."
                            }
                        }
                    }
                } catch {
                    // Ignore; fall back to error interpretation below.
                }
            }

            if errorMessage == nil {
                let nsError = error as NSError
                let systemStoppedCode: Int
                if #available(macOS 15.0, *) {
                    systemStoppedCode = SCStreamError.systemStoppedStream.rawValue
                } else {
                    systemStoppedCode = -3821
                }

                if nsError.domain == SCStreamErrorDomain, nsError.code == systemStoppedCode {
                    errorMessage = "Recording stopped by the system."
                } else {
                    errorMessage = "Recording stopped unexpectedly."
                }
            }
        }

        await finalizeRecording(stopCapture: false, isPartial: true)
    }

    private func finalizeRecording(stopCapture: Bool, isPartial: Bool) async {
        guard !isFinalizing else { return }
        isFinalizing = true
        defer { isFinalizing = false }

        guard state != .idle else { return }
        state = .stopping
        diagnosticsTask?.cancel()
        diagnosticsTask = nil

        if stopCapture {
            do {
                try await captureEngine.stopCapture()
            } catch {
                // Ignore: stream might already be stopped.
            }
        }

        let failedTemporaryURL = recordingPipeline?.temporaryURL
        let outputURL: URL?
        var finalizationError: EncodingPipelineError?
        if let recordingPipeline {
            do {
                outputURL = try await recordingPipeline.finishWriting()
            } catch let error as EncodingPipelineError {
                outputURL = nil
                finalizationError = error
            } catch {
                outputURL = nil
                finalizationError = .writerFailed
            }
        } else {
            outputURL = nil
        }

        await logRecordingDiagnostics(phase: "final")

        self.recordingPipeline = nil
        activeFacecamCompositor = nil
        fileSizeTask?.cancel()
        fileSizeTask = nil
        diskSpaceTask?.cancel()
        diskSpaceTask = nil
        captureEngine.onVideoSampleBuffer = nil
        captureEngine.onAudioSampleBuffer = nil
        captureEngine.onMicrophoneSampleBuffer = nil
        captureEngine.onStop = nil
        audioMixer.onSystemAudio = nil
        audioMixer.onMicrophoneAudio = nil
        isMicrophoneCaptureActive = false
        if isFacecamRecordingConsumerActive {
            await cameraAccessController?.setRecordingConsumerActive(false)
            isFacecamRecordingConsumerActive = false
        }
        recordingState.isRecording = false
        state = .idle
        facecamWarningMessage = nil
        isFacecamIntentionallyDisabledDuringRecording = false

        if let outputURL {
            recordingState.currentFile = outputURL
            recordingState.lastSavedFile = outputURL
            recordingState.currentFileSizeBytes =
                (try? RecordingArtifactPolicy.regularFileSize(at: outputURL)) ?? 0

            notificationManager.postRecordingSaved(url: outputURL, isPartial: isPartial)
        } else if let finalizationError {
            recordingState.currentFile = nil
            recordingState.currentFileSizeBytes = 0
            if let failedTemporaryURL {
                registerOrphanedTemporaryFileIfPresent(failedTemporaryURL)
            }

            let message = finalizationError.localizedDescription
            if let existingMessage = errorMessage, !existingMessage.contains(message) {
                errorMessage = existingMessage + " " + message
            } else if errorMessage == nil {
                errorMessage = message
            }
            notificationManager.postWarning(title: "Recording not saved", message: message)
        }
    }

    func retryFacecamCapture() async {
        await cameraAccessController?.refreshAfterSystemSettingsChange()
    }

    func handleFacecamCompositorEvent(_ event: FacecamVideoCompositorEvent) {
        guard state == .recording || state == .preparing else { return }

        switch event {
        case .cameraUnavailable:
            guard !isFacecamIntentionallyDisabledDuringRecording else { return }
            facecamWarningMessage = "Camera unavailable. Screen and audio recording are continuing. Unlock or reconnect the camera, choose another camera, or use Check Again."
        case .cameraRecovered:
            facecamWarningMessage = nil
        }
    }

    private func startDiagnosticsSampling() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.logRecordingDiagnostics(phase: "start")

            while !Task.isCancelled, self.recordingState.isRecording {
                do {
                    try await Task.sleep(for: Self.diagnosticsInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.recordingState.isRecording else { return }
                await self.logRecordingDiagnostics(phase: "periodic")
            }
        }
    }

    private func logRecordingDiagnostics(phase: String) async {
        guard let recordingPipeline else { return }

        let snapshot = RecordingRuntimeDiagnosticsSnapshot(
            phase: phase,
            elapsedSeconds: max(0, Int(recordingState.elapsedTime.rounded(.down))),
            capture: await captureEngine.sampleMetrics(),
            ingestion: recordingPipeline.ingestionMetrics(),
            delivery: recordingPipeline.deliveryMetrics(),
            cameraMailbox: activeFacecamCompositor == nil ? nil : cameraFrameProvider?.frameMetrics(),
            facecam: activeFacecamCompositor?.diagnostics()
        )
        Self.performanceLogger.info("\(snapshot.logMessage, privacy: .public)")
    }

    private func registerOrphanedTemporaryFileIfPresent(_ url: URL) {
        guard RecordingArtifactPolicy.kind(for: url, in: preferences.outputDirectory) != nil else {
            return
        }
        guard
            let fileSize = try? RecordingArtifactPolicy.regularFileSize(at: url),
            fileSize > 0,
            !orphanedTempFiles.contains(url)
        else {
            return
        }

        orphanedTempFiles.append(url)
    }

    private func handleError(_ error: Error, userMessage: String) {
        if errorMessage == nil {
            if let coordinatorError = error as? RecordingCoordinatorError {
                errorMessage = coordinatorError.localizedDescription
            } else {
                errorMessage = userMessage
            }
        }
        print("\(userMessage) \(error)")
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        guard
            let screen = NSScreen.screens.first(where: { screen in
                guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return false
                }
                return CGDirectDisplayID(screenNumber.uint32Value) == displayID
            })
        else {
            return "Display \(displayID)"
        }

        return screen.localizedName
    }

    private func displayResolutionLabel(for display: SCDisplay) -> String {
        let scale: CGFloat
        if let screen = NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == display.displayID
        }) {
            scale = screen.backingScaleFactor
        } else {
            scale = 1
        }

        let width = Int((CGFloat(display.width) * scale).rounded())
        let height = Int((CGFloat(display.height) * scale).rounded())
        return "\(width)×\(height)"
    }

    private func observePreferences() {
        withObservationTracking {
            _ = preferences.micEnabled
            _ = preferences.selectedMicDeviceID
            _ = preferences.selectedDisplayID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyPreferences()
                self.observePreferences()
            }
        }
    }

    private func applyPreferences() {
        let desiredMicrophoneID = preferences.selectedMicDeviceID ?? MicrophoneOption.noneID
        if selectedMicrophoneID != desiredMicrophoneID {
            selectedMicrophoneID = desiredMicrophoneID
        }

        let effectiveMicEnabled = preferences.micEnabled && preferences.selectedMicDeviceID != nil
        if isMicrophoneEnabled != effectiveMicEnabled {
            isMicrophoneEnabled = effectiveMicEnabled
        }

        if state == .idle, let displayID = preferences.selectedDisplayID {
            let currentToken = CaptureSourceToken(rawValue: selectedCaptureSourceToken)
            let shouldApplyDisplay = selectedCaptureSourceToken.isEmpty || currentToken == nil || currentToken?.kind == .display
            if shouldApplyDisplay {
                let token = CaptureSourceToken.display(displayID).rawValue
                if selectedCaptureSourceToken != token {
                    selectedCaptureSourceToken = token
                }
            }
        }

        audioMixer.setMicrophoneEnabled(isMicrophoneCaptureActive && isMicrophoneEnabled)
    }
}
