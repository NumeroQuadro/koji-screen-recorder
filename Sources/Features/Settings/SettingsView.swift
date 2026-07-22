import AppKit
import AVFoundation
import Observation
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    @Bindable var recordingCoordinator: RecordingCoordinator
    @Bindable var updateManager: UpdateManager
    let showWelcomeScreen: () -> Void

    @State private var showingHotkeyCapture = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            recordingTab
                .tabItem { Label("Recording", systemImage: "record.circle") }

            audioTab
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }

            hotkeyTab
                .tabItem { Label("Hotkey", systemImage: "keyboard") }

            updatesTab
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .tabViewStyle(.automatic)
        .padding(16)
        .frame(width: 560, height: 420)
        .task {
            await recordingCoordinator.refreshMicrophones()
            await recordingCoordinator.refreshCaptureSources()
        }
    }

    private var generalTab: some View {
        Form {
            Section("Output") {
                HStack(alignment: .firstTextBaseline) {
                    Text("Directory")
                    Spacer()
                    Text(preferences.outputDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 340, alignment: .trailing)
                }

                HStack {
                    Spacer()
                    Button("Choose…") {
                        chooseOutputDirectory()
                    }
                }

                Picker("Container", selection: $preferences.containerFormat) {
                    ForEach(Preferences.ContainerFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $preferences.launchAtLogin)
            }

            Section("Welcome") {
                Button("Show Welcome Screen") {
                    showWelcomeScreen()
                }
                Text("Re-run the first-launch walkthrough.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var recordingTab: some View {
        Form {
            Section("Video") {
                Picker("Quality", selection: $preferences.recordingQuality) {
                    ForEach(Preferences.RecordingQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.segmented)

                Text(preferences.recordingQuality.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Codec", selection: $preferences.videoCodec) {
                    ForEach(Preferences.VideoCodec.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }

                Picker("Frame Rate", selection: $preferences.frameRate) {
                    ForEach(Preferences.FrameRate.allCases) { rate in
                        Text("\(rate.rawValue) fps").tag(rate)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show Cursor", isOn: $preferences.showCursor)
            }

            Section("Default Capture") {
                Picker("Display", selection: defaultDisplayBinding) {
                    Text("Primary Display").tag(CGDirectDisplayID?.none)

                    ForEach(displayPickerOptions) { option in
                        Text(option.label).tag(CGDirectDisplayID?(option.id))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var audioTab: some View {
        Form {
            Section("Microphone") {
                Picker("Input", selection: microphonePickerBinding) {
                    ForEach(recordingCoordinator.microphoneOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .disabled(recordingCoordinator.state != .idle)

                Toggle(
                    "Include Microphone in Recordings",
                    isOn: microphoneCaptureBinding
                )
                .disabled(!recordingCoordinator.canToggleMicrophone)

                if preferences.selectedMicDeviceID == nil {
                    Text("Select a microphone to enable mic capture.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if recordingCoordinator.state == .recording,
                          !recordingCoordinator.isMicrophoneCaptureActive {
                    Text("This recording started without a microphone track. This switch applies to the next recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                microphonePermissionMessage
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeyTab: some View {
        Form {
            Section("Global Hotkey") {
                HStack {
                    Text("Shortcut")
                    Spacer()

                    Text(preferences.globalHotkey?.displayString ?? "Disabled")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(showingHotkeyCapture ? "Press Keys…" : "Record Shortcut") {
                        showingHotkeyCapture.toggle()
                    }

                    Button("Clear") {
                        preferences.globalHotkey = nil
                    }
                    .disabled(preferences.globalHotkey == nil)

                    Spacer()
                }

                if showingHotkeyCapture {
                    HotkeyCaptureView { combo in
                        preferences.globalHotkey = combo
                        showingHotkeyCapture = false
                    }
                    .frame(height: 40)
                }

                Text("Tip: Use a combo unlikely to conflict with other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var updatesTab: some View {
        Form {
            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updateManager.automaticallyChecksForUpdates },
                        set: { updateManager.automaticallyChecksForUpdates = $0 }
                    )
                )

                HStack {
                    Button("Check Now") {
                        NSApp.activate(ignoringOtherApps: true)
                        updateManager.checkForUpdates()
                    }
                    .disabled(!updateManager.canCheckForUpdates)

                    Spacer()
                }

                Text("Last checked: \(lastCheckedLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            updateManager.startAutomaticChecks()
        }
    }

    private var lastCheckedLabel: String {
        guard let date = updateManager.lastUpdateCheck else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var microphonePickerBinding: Binding<String> {
        Binding(
            get: {
                preferences.selectedMicDeviceID ?? MicrophoneOption.noneID
            },
            set: { newValue in
                if newValue == MicrophoneOption.noneID {
                    preferences.selectedMicDeviceID = nil
                    preferences.micEnabled = false
                } else {
                    preferences.selectedMicDeviceID = newValue
                }
            }
        )
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

    @ViewBuilder
    private var microphonePermissionMessage: some View {
        if recordingCoordinator.isMicrophoneEnabled {
            switch recordingCoordinator.microphoneAuthorizationStatus {
            case .authorized:
                EmptyView()
            case .notDetermined:
                Text("Microphone permission has not been granted yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Microphone access is denied. Screen and system-audio recording remain available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Microphone Settings") {
                        Permissions.openMicrophoneSystemSettings()
                    }
                    .controlSize(.small)
                }
            case .restricted:
                Text("Microphone access is restricted on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            @unknown default:
                Text("Microphone access is unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var defaultDisplayBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: { preferences.selectedDisplayID },
            set: { newValue in
                preferences.selectedDisplayID = newValue
                if let newValue {
                    recordingCoordinator.selectedCaptureSourceToken = CaptureSourceToken.display(newValue).rawValue
                } else {
                    recordingCoordinator.selectedCaptureSourceToken = ""
                }
            }
        )
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = preferences.outputDirectory

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        preferences.outputDirectory = url
        preferences.ensureOutputDirectoryExists()
    }

    private func displayOption(from option: CaptureSourceOption) -> (id: CGDirectDisplayID, label: String)? {
        guard case let .display(displayID) = option.token else { return nil }
        let label: String
        if let subtitle = option.subtitle, !subtitle.isEmpty {
            label = "\(option.title) (\(subtitle))"
        } else {
            label = option.title
        }

        return (id: displayID, label: label)
    }

    private var displayPickerOptions: [DisplayPickerOption] {
        recordingCoordinator.displaySources
            .compactMap { displayOption(from: $0) }
            .map { DisplayPickerOption(id: $0.id, label: $0.label) }
            .sorted(by: { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
    }
}

private struct DisplayPickerOption: Identifiable {
    let id: CGDirectDisplayID
    let label: String
}

private struct HotkeyCaptureView: NSViewRepresentable {
    let onCapture: (KeyCombo) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HotkeyCaptureNSView()
        view.onCapture = onCapture
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class HotkeyCaptureNSView: NSView {
    var onCapture: ((KeyCombo) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        let combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers, key: key)
        onCapture?(combo)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        let text = "Press the new shortcut…"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 13),
        ]
        let size = text.size(withAttributes: attributes)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: rect, withAttributes: attributes)
    }
}
