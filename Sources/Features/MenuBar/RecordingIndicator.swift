import AppKit
import Observation
import QuartzCore

@MainActor
final class RecordingIndicator {
    private weak var statusButton: NSStatusBarButton?
    private let recordingState: RecordingState
    private let pulseKey = "Koji.RecordingIndicator.Pulse"

    init(statusButton: NSStatusBarButton, recordingState: RecordingState) {
        self.statusButton = statusButton
        self.recordingState = recordingState

        statusButton.wantsLayer = true

        apply(isRecording: recordingState.isRecording)
        observeRecordingState()
    }

    private func observeRecordingState() {
        withObservationTracking {
            _ = recordingState.isRecording
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(isRecording: self.recordingState.isRecording)
                self.observeRecordingState()
            }
        }
    }

    private func apply(isRecording: Bool) {
        guard let button = statusButton else { return }
        let symbolName = isRecording ? "record.circle.fill" : "display"

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Kōji")
        button.imagePosition = .imageOnly
        button.contentTintColor = isRecording ? .systemRed : nil

        setPulsing(isRecording)
    }

    private func setPulsing(_ pulsing: Bool) {
        guard let button = statusButton, let layer = button.layer else { return }

        if pulsing {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                layer.removeAnimation(forKey: pulseKey)
                button.alphaValue = 1.0
                return
            }
            guard layer.animation(forKey: pulseKey) == nil else { return }

            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1.0
            animation.toValue = 0.78
            animation.duration = 1.2
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: pulseKey)
        } else {
            layer.removeAnimation(forKey: pulseKey)
            button.alphaValue = 1.0
        }
    }
}
