import Foundation

struct RecordingRuntimeDiagnosticsSnapshot: Equatable, Sendable {
    let phase: String
    let elapsedSeconds: Int
    let capture: CaptureSampleMetrics
    let ingestion: EncodingBackpressureMetrics
    let delivery: EncodingDeliveryMetrics
    let cameraMailbox: LatestValueMailboxMetrics?
    let facecam: FacecamVideoCompositorDiagnostics?

    var logMessage: String {
        let cameraFields: String
        if let cameraMailbox, let facecam {
            let composition = facecam.composition
            let synchronization = facecam.synchronization
            cameraFields = [
                "cameraAccepted=\(cameraMailbox.acceptedCount)",
                "cameraReplaced=\(cameraMailbox.replacementCount)",
                "cameraCurrent=\(cameraMailbox.currentCount)",
                "cameraPeak=\(cameraMailbox.peakCount)",
                "composed=\(composition.composedFrameCount)",
                "screenOnly=\(composition.screenOnlyFrameCount)",
                "poolFailures=\(composition.destinationAllocationFailureCount)",
                "renderFailures=\(composition.renderFailureCount)",
                "cameraSelected=\(synchronization.selectedCameraFrameCount)",
                "cameraReused=\(synchronization.reusedCameraFrameCount)",
                "cameraFuture=\(synchronization.futureCameraFrameCount)",
                "cameraExpired=\(synchronization.expiredCameraFrameCount)",
                "cameraRegressed=\(synchronization.regressingCameraTimestampCount)",
                "cameraGenerations=\(synchronization.generationChangeCount)",
            ].joined(separator: " ")
        } else {
            cameraFields = "facecam=off"
        }

        return [
            "phase=\(phase)",
            "elapsed=\(elapsedSeconds)",
            "screenCallbacks=\(capture.screenCallbackCount)",
            "screenForwarded=\(capture.forwardedScreenFrameCount)",
            "audioCallbacks=\(capture.systemAudioCallbackCount)",
            "micCallbacks=\(capture.microphoneCallbackCount)",
            streamFields(name: "video", stream: ingestion.video),
            streamFields(name: "audio", stream: ingestion.systemAudio),
            streamFields(name: "mic", stream: ingestion.microphone),
            "videoAppended=\(delivery.appendedVideoFrameCount)",
            "videoNotReady=\(delivery.videoInputNotReadyCount)",
            "videoAppendFailures=\(delivery.videoAppendFailureCount)",
            "videoTimestampDrops=\(delivery.videoTimestampDropCount)",
            "audioAppended=\(delivery.appendedSystemAudioSampleCount)",
            "audioNotReady=\(delivery.systemAudioInputNotReadyCount)",
            "audioAppendFailures=\(delivery.systemAudioAppendFailureCount)",
            "micAppended=\(delivery.appendedMicrophoneSampleCount)",
            "micNotReady=\(delivery.microphoneInputNotReadyCount)",
            "micAppendFailures=\(delivery.microphoneAppendFailureCount)",
            cameraFields,
        ].joined(separator: " ")
    }

    private func streamFields(
        name: String,
        stream: EncodingBackpressureMetrics.Stream
    ) -> String {
        "\(name)Accepted=\(stream.acceptedSampleCount) "
            + "\(name)Dropped=\(stream.droppedSampleCount) "
            + "\(name)Pending=\(stream.pendingSampleCount) "
            + "\(name)Peak=\(stream.peakPendingSampleCount)"
    }
}
