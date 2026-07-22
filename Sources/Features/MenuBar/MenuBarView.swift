import AppKit
import AVFoundation
import Observation
import SwiftUI

struct MenuBarView: View {
    @Bindable var recordingState: RecordingState
    @Bindable var recordingCoordinator: RecordingCoordinator
    @Bindable var permissionsState: PermissionsState
    @Bindable var cameraAccessController: CameraAccessController
    @Bindable var preferences: Preferences
    let openSettings: () -> Void

    private var canRecord: Bool {
        permissionsState.screenRecording == .granted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if shouldShowPermissionsSection {
                    permissionsSection
                    Divider()
                }

                headerRow
                messageSection
                recoverySection
                captureSection
                statusSection

                recordButton

                if let savedFile = recordingState.lastSavedFile, !recordingState.isRecording {
                    savedSection(savedFile)
                }

                Divider()
                bottomRow
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 300)
        .task {
            await recordingCoordinator.refreshMicrophones()
            await recordingCoordinator.refreshCaptureSources()
        }
    }

    private var shouldShowPermissionsSection: Bool {
        permissionsState.screenRecording != .granted
            || shouldShowMicrophonePermissionSection
    }

    private var shouldShowMicrophonePermissionSection: Bool {
        MicrophoneCapturePolicy.shouldShowPermissionNotice(
            isMicrophoneEnabled: recordingCoordinator.isMicrophoneEnabled,
            permissionStatus: permissionsState.microphone
        )
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.headline)

            HStack {
                Text("Screen Recording")
                Spacer()
                Text(screenRecordingLabel)
                    .foregroundStyle(screenRecordingColor)
            }

            if permissionsState.screenRecording != .granted {
                Text("Grant Screen Recording access in System Settings → Privacy & Security → Screen Recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Open Settings") {
                        Permissions.openScreenRecordingSystemSettings()
                    }
                    Button("Check Again") {
                        Task {
                            await permissionsState.requestScreenRecording()
                            await recordingCoordinator.refreshCaptureSources()
                        }
                    }
                }
                .controlSize(.small)
            }

            if shouldShowMicrophonePermissionSection {
                HStack {
                    Text("Microphone")
                    Spacer()
                    Text(microphoneLabel)
                        .foregroundStyle(microphoneColor)
                }

                if permissionsState.microphone == .notDetermined {
                    Button("Request Microphone Access") {
                        Task { await permissionsState.requestMicrophone() }
                    }
                    .controlSize(.small)
                } else if permissionsState.microphone == .denied || permissionsState.microphone == .restricted {
                    Text("Grant Microphone access in System Settings → Privacy & Security → Microphone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Open Settings") {
                            Permissions.openMicrophoneSystemSettings()
                        }
                        Button("Check Again") {
                            Task {
                                await permissionsState.refresh()
                                await recordingCoordinator.refreshMicrophones()
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center) {
            Text("Kōji")
                .font(.headline)

            Spacer()

            Button {
                Task {
                    await recordingCoordinator.toggleMicrophoneEnabled()
                }
            } label: {
                Image(systemName: microphoneButtonIcon)
            }
            .buttonStyle(.plain)
            .disabled(microphoneButtonDisabled)
            .help(microphoneButtonHelp)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    @ViewBuilder
    private var messageSection: some View {
        if let error = recordingCoordinator.errorMessage {
            banner(
                title: "Error",
                message: error,
                background: Color.red.opacity(0.12),
                foreground: .red,
                primaryActionTitle: canRecord && recordingCoordinator.state == .idle ? "Retry" : nil,
                primaryAction: {
                    Task { await recordingCoordinator.toggleRecording() }
                },
                secondaryActionTitle: "Dismiss",
                secondaryAction: {
                    recordingCoordinator.errorMessage = nil
                }
            )
        } else if let warning = recordingCoordinator.facecamWarningMessage {
            banner(
                title: "Facecam Paused",
                message: warning,
                background: Color.orange.opacity(0.14),
                foreground: .orange,
                primaryActionTitle: "Check Again",
                primaryAction: {
                    Task { await recordingCoordinator.retryFacecamCapture() }
                },
                secondaryActionTitle: "Dismiss",
                secondaryAction: {
                    recordingCoordinator.facecamWarningMessage = nil
                }
            )
        } else if let warning = recordingCoordinator.warningMessage {
            banner(
                title: "Warning",
                message: warning,
                background: Color.orange.opacity(0.14),
                foreground: .orange,
                primaryActionTitle: nil,
                primaryAction: {},
                secondaryActionTitle: "Dismiss",
                secondaryAction: {
                    recordingCoordinator.warningMessage = nil
                }
            )
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        if recordingCoordinator.discardedArtifactCount > 0
            || !recordingCoordinator.recoveredFiles.isEmpty
            || !recordingCoordinator.orphanedTempFiles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recovery")
                    .font(.headline)

                if recordingCoordinator.discardedArtifactCount > 0 {
                    Text("Removed \(recordingCoordinator.discardedArtifactCount) empty crash artifact(s).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !recordingCoordinator.recoveredFiles.isEmpty {
                    Text("Recovered \(recordingCoordinator.recoveredFiles.count) unfinished recording(s).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(recordingCoordinator.recoveredFiles.prefix(2), id: \.self) { url in
                        Button(url.lastPathComponent) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                if !recordingCoordinator.orphanedTempFiles.isEmpty {
                    Text("Orphaned temp file(s):")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(recordingCoordinator.orphanedTempFiles.prefix(2), id: \.self) { url in
                        HStack(spacing: 6) {
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.plain)
                            .help("Reveal")

                            Button(role: .destructive) {
                                recordingCoordinator.deleteOrphanedRecording(url)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Delete")
                        }
                    }
                }
            }
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capture")
                .font(.headline)

            captureSourceRow
            microphonePickerRow
            microphoneToggleRow
            facecamToggleRow
            facecamSetupSection
        }
    }

    private var captureSourceRow: some View {
        HStack(alignment: .center) {
            Text("Source")
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                captureSourceMenu
            } label: {
                HStack(spacing: 4) {
                    Text(recordingCoordinator.selectedCaptureSourceTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(recordingState.isRecording || recordingCoordinator.state.isBusy || !canRecord)
        }
    }

    private var microphonePickerRow: some View {
        HStack(alignment: .center) {
            Text("Microphone")
                .foregroundStyle(.secondary)
            Spacer()

            Picker("", selection: $recordingCoordinator.selectedMicrophoneID) {
                ForEach(recordingCoordinator.microphoneOptions) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .disabled(recordingState.isRecording || recordingCoordinator.state.isBusy)
        }
    }

    private var microphoneToggleRow: some View {
        Toggle(isOn: microphoneCaptureBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Include Microphone")
                Text(microphoneToggleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!recordingCoordinator.canToggleMicrophone)
    }

    private var facecamToggleRow: some View {
        Toggle(isOn: facecamEnabledBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Facecam")
                Text("Set up an iPhone or another camera for the presenter overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(recordingState.isRecording || cameraAccessController.isRequestingAuthorization)
    }

    @ViewBuilder
    private var facecamSetupSection: some View {
        if cameraAccessController.isFacecamEnabled {
            if !cameraAccessController.cameraOptions.isEmpty
                || cameraAccessController.accessState == .disconnected {
                cameraPickerRow
            }

            if cameraAccessController.canUseFacecam {
                facecamSizeRow
            }

            switch cameraAccessController.accessState {
            case .notDetermined:
                Text(cameraAccessController.isRequestingAuthorization
                    ? "Waiting for camera permission…"
                    : "Camera permission has not been requested yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .authorized:
                cameraPreviewSection

            case .denied:
                cameraRecoveryMessage(
                    "Camera access is off. Screen and audio recording remain available."
                )

            case .restricted:
                cameraRecoveryMessage(
                    "Camera access is restricted on this Mac. Screen and audio recording remain available."
                )

            case .unavailable:
                VStack(alignment: .leading, spacing: 5) {
                    Text("No camera is available. Unlock and place your iPhone nearby, or connect a camera.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Check Again") {
                        Task { await cameraAccessController.refreshAfterSystemSettingsChange() }
                    }
                    .controlSize(.small)
                }

            case .disconnected:
                Text("Your selected camera is disconnected. \(Brand.appName) will remain screen/audio-only until it returns or you choose another camera.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var cameraPreviewSection: some View {
        switch cameraAccessController.captureState {
        case .inactive, .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting camera preview…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .previewing, .recording, .previewingAndRecording:
            CameraPreviewView(session: cameraAccessController.previewSession)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                }

            if let format = cameraAccessController.negotiatedFormat {
                Text("Live preview · \(format.width)×\(format.height) · \(formattedCameraFrameRate(format.frameRate)) fps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case let .failed(error):
            VStack(alignment: .leading, spacing: 5) {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Check Again") {
                    Task { await cameraAccessController.retryCapture() }
                }
                .controlSize(.small)
            }
        }
    }

    private var cameraPickerRow: some View {
        HStack(alignment: .center) {
            Text("Camera")
                .foregroundStyle(.secondary)
            Spacer()

            Picker("", selection: cameraSelectionBinding) {
                Text("Automatic").tag(CameraSelection.automatic)

                if case let .manual(deviceID) = cameraAccessController.selection,
                   !cameraAccessController.cameraOptions.contains(where: { $0.id == deviceID }) {
                    Text("Disconnected camera")
                        .tag(CameraSelection.manual(deviceID: deviceID))
                }

                ForEach(cameraAccessController.cameraOptions) { option in
                    Text(option.menuTitle)
                        .tag(CameraSelection.manual(deviceID: option.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 190)
            .disabled(cameraAccessController.isRequestingAuthorization)
        }
    }

    private var facecamSizeRow: some View {
        HStack(alignment: .center) {
            Text("Overlay Size")
                .foregroundStyle(.secondary)
            Spacer()

            Picker("", selection: facecamSizeBinding) {
                ForEach(FacecamSizePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 190)
        }
    }

    private func cameraRecoveryMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Open Settings") {
                    Permissions.openCameraSystemSettings()
                }
                Button("Check Again") {
                    Task { await cameraAccessController.refreshAfterSystemSettingsChange() }
                }
            }
            .controlSize(.small)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.headline)

            timerRow
            fileSizeRow
        }
    }

    private var timerRow: some View {
        HStack {
            Text("Elapsed")
                .foregroundStyle(.secondary)
            Spacer()
            Text(recordingState.formattedElapsedTime)
                .font(.system(.title3, design: .monospaced))
        }
    }

    private var fileSizeRow: some View {
        HStack {
            Text("File Size")
                .foregroundStyle(.secondary)
            Spacer()
            Text(recordingState.formattedFileSize)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                await recordingCoordinator.toggleRecording()
            }
        } label: {
            Text(recordingState.isRecording ? "Stop" : "Record")
                .frame(maxWidth: .infinity)
                .font(.system(.title3, weight: .semibold))
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(recordingState.isRecording ? .red : .accentColor)
        .disabled(!canRecord || recordingCoordinator.state.isBusy)
    }

    private var bottomRow: some View {
        HStack {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")

            Spacer()

            if let currentFile = recordingState.currentFile {
                Text(currentFile.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func savedSection(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved to \(url.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func banner(
        title: String,
        message: String,
        background: Color,
        foreground: Color,
        primaryActionTitle: String?,
        primaryAction: @escaping () -> Void,
        secondaryActionTitle: String,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(foreground)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if let primaryActionTitle {
                    Button(primaryActionTitle, action: primaryAction)
                        .controlSize(.small)
                }
                Button(secondaryActionTitle, action: secondaryAction)
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(8)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var captureSourceMenu: some View {
        if !recordingCoordinator.displaySources.isEmpty {
            menuHeader("Displays")
            ForEach(recordingCoordinator.displaySources) { source in
                Button {
                    recordingCoordinator.selectedCaptureSourceToken = source.id
                } label: {
                    menuRow(source: source, icon: Image(systemName: "display"))
                }
            }
        }

        if !recordingCoordinator.applicationSources.isEmpty {
            Divider()
            menuHeader("Applications")
            ForEach(recordingCoordinator.applicationSources) { source in
                Button {
                    recordingCoordinator.selectedCaptureSourceToken = source.id
                } label: {
                    menuRow(source: source, icon: applicationIcon(for: source.token))
                }
            }
        }

        if !recordingCoordinator.windowSources.isEmpty {
            Divider()
            menuHeader("Windows")
            ForEach(recordingCoordinator.windowSources.prefix(30)) { source in
                Button {
                    recordingCoordinator.selectedCaptureSourceToken = source.id
                } label: {
                    menuRow(source: source, icon: Image(systemName: "macwindow"))
                }
            }
        }
    }

    private func menuHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(true)
    }

    private func menuRow(source: CaptureSourceOption, icon: Image?) -> some View {
        HStack(spacing: 8) {
            if source.id == recordingCoordinator.selectedCaptureSourceToken {
                Image(systemName: "checkmark")
            } else {
                Image(systemName: "checkmark").hidden()
            }

            if let icon {
                icon
            }

            if let subtitle = source.subtitle, !subtitle.isEmpty {
                Text("\(source.title) (\(subtitle))")
            } else {
                Text(source.title)
            }
        }
    }

    private func applicationIcon(for token: CaptureSourceToken) -> Image? {
        guard case let .application(bundleIdentifier) = token else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return Image(systemName: "app") }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return Image(nsImage: image)
    }

    private var microphoneButtonIcon: String {
        if recordingCoordinator.selectedMicrophoneID == MicrophoneOption.noneID {
            return "mic.slash"
        }
        if recordingCoordinator.state == .recording,
           !recordingCoordinator.isMicrophoneCaptureActive {
            return "mic.slash"
        }
        return recordingCoordinator.isMicrophoneEnabled ? "mic.fill" : "mic.slash"
    }

    private var microphoneButtonDisabled: Bool {
        !recordingCoordinator.canToggleMicrophone
    }

    private var microphoneButtonHelp: String {
        if recordingCoordinator.selectedMicrophoneID == MicrophoneOption.noneID {
            return "Select a microphone to enable it"
        }
        if recordingCoordinator.state == .recording, !recordingCoordinator.isMicrophoneCaptureActive {
            return recordingCoordinator.isMicrophoneEnabled
                ? "Microphone enabled for the next recording; the current recording has no microphone track"
                : "Enable microphone for the next recording"
        }
        return recordingCoordinator.isMicrophoneEnabled ? "Microphone on" : "Microphone off"
    }

    private var microphoneCaptureBinding: Binding<Bool> {
        Binding(
            get: { recordingCoordinator.isMicrophoneEnabled },
            set: { isEnabled in
                Task {
                    await recordingCoordinator.setMicrophoneEnabled(isEnabled)
                }
            }
        )
    }

    private var facecamEnabledBinding: Binding<Bool> {
        Binding(
            get: { cameraAccessController.isFacecamEnabled },
            set: { isEnabled in
                Task {
                    await recordingCoordinator.setFacecamEnabled(isEnabled)
                }
            }
        )
    }

    private var cameraSelectionBinding: Binding<CameraSelection> {
        Binding(
            get: { cameraAccessController.selection },
            set: { selection in
                Task {
                    await cameraAccessController.selectCamera(selection)
                }
            }
        )
    }

    private var facecamSizeBinding: Binding<FacecamSizePreset> {
        Binding(
            get: { preferences.facecamPlacement.sizePreset },
            set: { sizePreset in
                var placement = preferences.facecamPlacement
                placement.sizePreset = sizePreset
                preferences.facecamPlacement = placement
            }
        )
    }

    private func formattedCameraFrameRate(_ frameRate: Double) -> String {
        if frameRate.rounded() == frameRate {
            return String(Int(frameRate))
        }
        return frameRate.formatted(.number.precision(.fractionLength(2)))
    }

    private var microphoneToggleSummary: String {
        if recordingCoordinator.selectedMicrophoneID == MicrophoneOption.noneID {
            return "Select a microphone to capture your voice."
        }

        if recordingCoordinator.state == .recording,
           !recordingCoordinator.isMicrophoneCaptureActive {
            if recordingCoordinator.isMicrophoneEnabled {
                return "Enabled for the next recording. This recording remains system audio only."
            }
            return "This recording has no microphone track. Turn this on for the next recording."
        }

        return "Records your voice alongside system audio and stays saved for future recordings."
    }

    private var screenRecordingLabel: String {
        switch permissionsState.screenRecording {
        case .unknown:
            "Unknown"
        case .granted:
            "Granted"
        case .denied:
            "Denied"
        }
    }

    private var screenRecordingColor: Color {
        switch permissionsState.screenRecording {
        case .unknown:
            .secondary
        case .granted:
            .green
        case .denied:
            .red
        }
    }

    private var microphoneLabel: String {
        switch permissionsState.microphone {
        case .authorized:
            "Granted"
        case .notDetermined:
            "Not requested"
        case .denied:
            "Denied"
        case .restricted:
            "Restricted"
        @unknown default:
            "Unknown"
        }
    }

    private var microphoneColor: Color {
        switch permissionsState.microphone {
        case .authorized:
            .green
        case .notDetermined:
            .secondary
        case .denied, .restricted:
            .red
        @unknown default:
            .secondary
        }
    }
}
