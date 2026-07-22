import XCTest
@testable import Koji

final class RecordingRuntimeDiagnosticsTests: XCTestCase {
    func testLogMessageContainsBoundedPipelineAndFacecamCounters() {
        var capture = CaptureSampleMetrics()
        capture.screenCallbackCount = 1_800
        capture.forwardedScreenFrameCount = 1_790
        capture.systemAudioCallbackCount = 900
        capture.microphoneCallbackCount = 450

        var delivery = EncodingDeliveryMetrics()
        delivery.appendedVideoFrameCount = 1_780
        delivery.videoInputNotReadyCount = 4
        delivery.appendedSystemAudioSampleCount = 890
        delivery.appendedMicrophoneSampleCount = 445

        var composition = FacecamVideoCompositorMetrics()
        composition.composedFrameCount = 1_770
        composition.screenOnlyFrameCount = 10

        var synchronization = CameraFrameSynchronizationMetrics()
        synchronization.selectedCameraFrameCount = 899
        synchronization.reusedCameraFrameCount = 871
        synchronization.expiredCameraFrameCount = 10
        synchronization.generationChangeCount = 1

        let snapshot = RecordingRuntimeDiagnosticsSnapshot(
            phase: "periodic",
            elapsedSeconds: 60,
            capture: capture,
            ingestion: EncodingBackpressureMetrics(
                isAcceptingSamples: true,
                video: stream(accepted: 1_790, dropped: 10, pending: 1, peak: 2),
                systemAudio: stream(accepted: 900, dropped: 0, pending: 0, peak: 3),
                microphone: stream(accepted: 450, dropped: 0, pending: 0, peak: 2)
            ),
            delivery: delivery,
            cameraMailbox: LatestValueMailboxMetrics(
                acceptedCount: 900,
                replacementCount: 899,
                currentCount: 1,
                peakCount: 1
            ),
            facecam: FacecamVideoCompositorDiagnostics(
                composition: composition,
                synchronization: synchronization
            )
        )

        let message = snapshot.logMessage

        XCTAssertTrue(message.contains("phase=periodic elapsed=60"))
        XCTAssertTrue(message.contains("videoDropped=10 videoPending=1 videoPeak=2"))
        XCTAssertTrue(message.contains("cameraCurrent=1 cameraPeak=1"))
        XCTAssertTrue(message.contains("composed=1770 screenOnly=10"))
        XCTAssertTrue(message.contains("cameraReused=871"))
        XCTAssertTrue(message.contains("cameraExpired=10"))
        XCTAssertTrue(message.contains("cameraGenerations=1"))
    }

    func testFacecamDisabledLogDoesNotInventCameraCounters() {
        let snapshot = RecordingRuntimeDiagnosticsSnapshot(
            phase: "final",
            elapsedSeconds: 12,
            capture: CaptureSampleMetrics(),
            ingestion: EncodingBackpressureMetrics(
                isAcceptingSamples: false,
                video: stream(accepted: 1, dropped: 0, pending: 0, peak: 1),
                systemAudio: stream(accepted: 1, dropped: 0, pending: 0, peak: 1),
                microphone: stream(accepted: 0, dropped: 0, pending: 0, peak: 0)
            ),
            delivery: EncodingDeliveryMetrics(),
            cameraMailbox: nil,
            facecam: nil
        )

        XCTAssertTrue(snapshot.logMessage.contains("facecam=off"))
        XCTAssertFalse(snapshot.logMessage.contains("cameraAccepted="))
    }

    private func stream(
        accepted: Int,
        dropped: Int,
        pending: Int,
        peak: Int
    ) -> EncodingBackpressureMetrics.Stream {
        EncodingBackpressureMetrics.Stream(
            acceptedSampleCount: accepted,
            droppedSampleCount: dropped,
            pendingSampleCount: pending,
            peakPendingSampleCount: peak
        )
    }
}
