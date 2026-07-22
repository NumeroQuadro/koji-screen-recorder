import CoreMedia
import os.lock

final class AudioMixer: @unchecked Sendable {
    private let isMicrophoneEnabledLock = OSAllocatedUnfairLock(initialState: true)
    private let resampler = AudioResampler()

    var onSystemAudio: ((CMSampleBuffer) -> Void)?
    var onMicrophoneAudio: ((CMSampleBuffer) -> Void)?

    func setMicrophoneEnabled(_ enabled: Bool) {
        isMicrophoneEnabledLock.withLock { isEnabled in
            isEnabled = enabled
        }
    }

    func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        if let resampled = resampler.resampleIfNeeded(sampleBuffer) {
            onSystemAudio?(resampled)
        } else {
            onSystemAudio?(sampleBuffer)
        }
    }

    func handleMicrophoneAudio(_ sampleBuffer: CMSampleBuffer) {
        let isMicrophoneEnabled = isMicrophoneEnabledLock.withLock { $0 }
        guard isMicrophoneEnabled else { return }

        if let resampled = resampler.resampleIfNeeded(sampleBuffer) {
            onMicrophoneAudio?(resampled)
        } else {
            onMicrophoneAudio?(sampleBuffer)
        }
    }
}
