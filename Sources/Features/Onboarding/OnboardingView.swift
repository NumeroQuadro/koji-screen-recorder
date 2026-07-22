import AppKit
import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome
        case screenRecording
        case microphone
        case ready

        var index: Int { rawValue }
    }

    let onStartRecording: () -> Void

    @State private var step: Step = .welcome
    @State private var movingForward = true
    @State private var permissionsState = PermissionsState()

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                ZStack {
                    currentStepView
                        .id(step)
                        .transition(stepTransition)
                        .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                stepDots
                    .padding(.bottom, 18)
            }
        }
        .frame(width: 500, height: 400)
        .tint(Brand.accentColor)
        .preferredColorScheme(.dark)
        .onChange(of: step) { _, newValue in
            if newValue == .microphone {
                permissionsState.microphone = Permissions.microphoneAuthorizationStatus()
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Brand.darkBackground,
                Color.black.opacity(0.92),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { candidate in
                Circle()
                    .fill(candidate == step ? Brand.accentColor : Color.white.opacity(0.18))
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(candidate == step ? 0.25 : 0.0), lineWidth: 1)
                    )
            }
        }
        .accessibilityLabel("Onboarding step \(step.index + 1) of \(Step.allCases.count)")
    }

    private var stepTransition: AnyTransition {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .opacity
        }

        let insertion = AnyTransition
            .move(edge: movingForward ? .trailing : .leading)
            .combined(with: .opacity)
        let removal = AnyTransition
            .move(edge: movingForward ? .leading : .trailing)
            .combined(with: .opacity)
        return .asymmetric(insertion: insertion, removal: removal)
    }

    @ViewBuilder
    private var currentStepView: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .screenRecording:
            screenRecordingStep
        case .microphone:
            microphoneStep
        case .ready:
            readyStep
        }
    }

    private func go(to newStep: Step) {
        movingForward = newStep.rawValue > step.rawValue
        withAnimation(.easeInOut(duration: 0.28)) {
            step = newStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 10)

            VStack(spacing: 10) {
                Text("Welcome to \(Brand.appName)")
                    .font(.system(size: 28, weight: .semibold))

                Text("Record your screen with all audio — calls, music, system sounds — no drivers needed.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
            }

            Spacer(minLength: 0)

            Button {
                go(to: .screenRecording)
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
        }
    }

    private var screenRecordingStep: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            PermissionIcon(systemName: "display", badgeSystemName: "record.circle.fill")

            VStack(spacing: 10) {
                Text("\(Brand.appName) needs Screen Recording access")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                Text("This lets \(Brand.appName) capture your display and system audio, including sound from Zoom, Meet, and other apps.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }

            if permissionsState.screenRecording == .granted {
                PermissionResultRow(
                    icon: "checkmark.circle.fill",
                    text: "Screen Recording access granted",
                    color: .green
                )
                .transition(.opacity)
            } else if permissionsState.screenRecording == .denied {
                Button("Open System Settings") {
                    Permissions.openScreenRecordingSystemSettings()
                }
                .buttonStyle(.link)
            }

            Spacer(minLength: 0)

            Group {
                if permissionsState.screenRecording == .granted {
                    Button {
                        go(to: .microphone)
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        Task { @MainActor in
                            await permissionsState.requestScreenRecording()
                        }
                    } label: {
                        Text("Grant Access")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
        }
    }

    private var microphoneStep: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            PermissionIcon(systemName: "mic.fill", badgeSystemName: nil)

            VStack(spacing: 10) {
                Text("Optional: Record your own voice")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                Text("Enable this to include your microphone in recordings. Great for meetings and calls.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }

            if permissionsState.microphone == .authorized {
                PermissionResultRow(
                    icon: "checkmark.circle.fill",
                    text: "Microphone enabled",
                    color: .green
                )
            } else if permissionsState.microphone == .denied || permissionsState.microphone == .restricted {
                Button("Open System Settings") {
                    Permissions.openMicrophoneSystemSettings()
                }
                .buttonStyle(.link)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    Task { @MainActor in
                        await permissionsState.requestMicrophone()
                        go(to: .ready)
                    }
                } label: {
                    Text("Enable Microphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    go(to: .ready)
                } label: {
                    Text("Skip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 40)
        }
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            ReadyPointerIllustration()

            VStack(spacing: 10) {
                Text("You’re all set!")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Click the \(Brand.appName) icon in your menu bar to start recording.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }

            Spacer(minLength: 0)

            Button {
                onStartRecording()
            } label: {
                Text("Start Recording")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
        }
    }
}

private struct PermissionResultRow: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
        }
        .foregroundStyle(color)
        .font(.subheadline)
        .fontWeight(.medium)
    }
}

private struct PermissionIcon: View {
    let systemName: String
    let badgeSystemName: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .frame(width: 96, height: 96)

            Image(systemName: systemName)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            if let badgeSystemName {
                Image(systemName: badgeSystemName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Brand.accentColor, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .offset(x: 28, y: 28)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ReadyPointerIllustration: View {
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .frame(width: 320, height: 150)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 24)

                Spacer()
            }
            .frame(width: 320, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 6) {
                Image(systemName: "menubar.rectangle")
                Text("Menu bar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Brand.accentColor)
                .offset(x: 126, y: -18)

            Circle()
                .fill(Brand.accentColor)
                .frame(width: 10, height: 10)
                .offset(x: 140, y: 12)
        }
        .accessibilityHidden(true)
    }
}
