import CoreMedia
import Foundation
import ScreenCaptureKit

enum CaptureEngineError: Error {
    case alreadyCapturing
    case notCapturing
}

actor CaptureEngine {
    private let sampleHandlerQueue = DispatchQueue(label: "Koji.CaptureEngine.sampleHandler")
    private let streamHandler = StreamHandler()
    private let defaults: UserDefaults
    private var stream: SCStream?

    nonisolated(unsafe) var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    nonisolated(unsafe) var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    nonisolated(unsafe) var onMicrophoneSampleBuffer: ((CMSampleBuffer) -> Void)?
    nonisolated(unsafe) var onStop: ((Error) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        streamHandler.engine = self
    }

    func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.current
    }

    func startCapture(filter: SCContentFilter, config: SCStreamConfiguration) async throws {
        guard stream == nil else { throw CaptureEngineError.alreadyCapturing }

        streamHandler.resetMetrics()

        let microphonePreferences = Preferences.microphonePreferenceState(from: defaults)
        let capturesMicrophone: Bool
        if #available(macOS 15.0, *) {
            capturesMicrophone = MicrophoneCapturePolicy.shouldCaptureMicrophoneTrack(
                isMicrophoneEnabled: microphonePreferences.isCaptureEnabled,
                requestedCapture: config.captureMicrophone
            )

            if !capturesMicrophone {
                config.captureMicrophone = false
                config.microphoneCaptureDeviceID = nil
            }
        } else {
            capturesMicrophone = false
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: streamHandler)
        try stream.addStreamOutput(streamHandler, type: .screen, sampleHandlerQueue: sampleHandlerQueue)
        if config.capturesAudio {
            try stream.addStreamOutput(streamHandler, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        }

        if #available(macOS 15.0, *), capturesMicrophone {
            try stream.addStreamOutput(streamHandler, type: .microphone, sampleHandlerQueue: sampleHandlerQueue)
        }
        try await stream.startCapture()

        self.stream = stream
    }

    func sampleMetrics() -> CaptureSampleMetrics {
        streamHandler.sampleMetrics()
    }

    func stopCapture() async throws {
        guard let stream else { throw CaptureEngineError.notCapturing }
        self.stream = nil

        try await stream.stopCapture()
    }

    fileprivate func handleStreamStopped() {
        stream = nil
    }
}

private final class StreamHandler: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var engine: CaptureEngine?
    private let diagnostics = CaptureSampleDiagnostics()

    func resetMetrics() {
        diagnostics.reset()
    }

    func sampleMetrics() -> CaptureSampleMetrics {
        diagnostics.snapshot()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            let disposition = ScreenCaptureSampleClassifier.classify(sampleBuffer)
            diagnostics.recordScreen(disposition)
            guard disposition == .usable else { return }
            engine?.onVideoSampleBuffer?(sampleBuffer)
        case .audio:
            diagnostics.recordSystemAudio()
            engine?.onAudioSampleBuffer?(sampleBuffer)
        case .microphone:
            diagnostics.recordMicrophone()
            engine?.onMicrophoneSampleBuffer?(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("CaptureEngine stopped with error: \(error)")
        engine?.onStop?(error)
        Task { [weak engine] in
            await engine?.handleStreamStopped()
        }
    }
}
