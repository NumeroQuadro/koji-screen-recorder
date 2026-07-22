import AVFoundation
import Foundation
import XCTest
@testable import Koji

@MainActor
final class RecordingArtifactTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var outputDirectory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "RecordingArtifactTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KojiRecordingArtifactTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outputDirectory)
        defaults.removePersistentDomain(forName: suiteName)
        outputDirectory = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testArtifactPolicyRecognizesOnlyExactGeneratedNamesInOutputDirectory() {
        let temporaryURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-51.recording.mp4"
        )
        let expectedFinalURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-51.mp4"
        )
        let sidecarURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-51.recording.mp4.sb-214a911e-va0Yiv"
        )

        XCTAssertEqual(
            RecordingArtifactPolicy.kind(for: temporaryURL, in: outputDirectory),
            .temporaryRecording(finalURL: expectedFinalURL)
        )
        XCTAssertEqual(
            RecordingArtifactPolicy.kind(for: sidecarURL, in: outputDirectory),
            .crashSidecar
        )

        let unrelatedNames = [
            "Vacation.recording.mp4",
            "Vacation.recording.mp4.sb-user-file",
            "Recording_2026-99-99_23-19-51.recording.mp4",
            "Recording_2026-07-16_23-19-51.recording.m4v",
            "Recording_2026-07-16_23-19-51.recording.mp4.sb-",
            "Recording_2026-07-16_23-19-51.mp4",
        ]

        for name in unrelatedNames {
            let url = outputDirectory.appendingPathComponent(name)
            XCTAssertNil(RecordingArtifactPolicy.kind(for: url, in: outputDirectory), name)
        }

        let outsideURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            temporaryURL.lastPathComponent
        )
        XCTAssertNil(RecordingArtifactPolicy.kind(for: outsideURL, in: outputDirectory))
    }

    func testOutputValidatorRejectsEmptyAndCorruptMedia() async throws {
        let emptyURL = outputDirectory.appendingPathComponent("empty.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: emptyURL.path, contents: Data()))

        do {
            try await RecordingOutputValidator().validateRecording(at: emptyURL)
            XCTFail("Expected an empty recording to fail validation")
        } catch let error as RecordingOutputValidationError {
            XCTAssertEqual(error, .emptyFile)
        }

        let corruptURL = outputDirectory.appendingPathComponent("corrupt.mp4")
        try Data("not a media container".utf8).write(to: corruptURL)

        do {
            try await RecordingOutputValidator().validateRecording(at: corruptURL)
            XCTFail("Expected corrupt media to fail validation")
        } catch let error as RecordingOutputValidationError {
            XCTAssertEqual(error, .unreadableMedia)
        }
    }

    func testArtifactPolicyReadsFreshSizeAfterURLResourceCacheIsWarmed() throws {
        let recordingURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-51.recording.mp4"
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: recordingURL.path, contents: Data()))

        let cachedValues = try recordingURL.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertEqual(cachedValues.fileSize, 0)

        try Data(repeating: 0x44, count: 4_096).write(to: recordingURL)

        XCTAssertEqual(try RecordingArtifactPolicy.regularFileSize(at: recordingURL), 4_096)
    }

    func testOutputValidatorRetriesTransientUnreadableMediaAndThenSucceeds() async throws {
        let recordingURL = outputDirectory.appendingPathComponent("transient.mp4")
        try Data([0x01]).write(to: recordingURL)
        let mediaAttempt = ScriptedMediaValidationAttempt(
            results: [.failure(.unreadableMedia), .success(())]
        )
        let sleeper = RecordingValidationSleeperSpy()
        let validator = RecordingOutputValidator(
            maximumMediaValidationAttempts: 3,
            retryDelay: .milliseconds(1),
            mediaValidationAttempt: mediaAttempt,
            sleeper: sleeper
        )

        try await validator.validateRecording(at: recordingURL)

        XCTAssertEqual(mediaAttempt.attemptCount, 2)
        XCTAssertEqual(sleeper.sleepCount, 1)
    }

    func testOutputValidatorDoesNotRetryMissingVideoTrack() async throws {
        let recordingURL = outputDirectory.appendingPathComponent("audio-only.mp4")
        try Data([0x01]).write(to: recordingURL)
        let mediaAttempt = ScriptedMediaValidationAttempt(
            results: [.failure(.missingVideoTrack)]
        )
        let sleeper = RecordingValidationSleeperSpy()
        let validator = RecordingOutputValidator(
            maximumMediaValidationAttempts: 4,
            retryDelay: .milliseconds(1),
            mediaValidationAttempt: mediaAttempt,
            sleeper: sleeper
        )

        do {
            try await validator.validateRecording(at: recordingURL)
            XCTFail("Expected missing video to fail validation")
        } catch let error as RecordingOutputValidationError {
            XCTAssertEqual(error, .missingVideoTrack)
        }

        XCTAssertEqual(mediaAttempt.attemptCount, 1)
        XCTAssertEqual(sleeper.sleepCount, 0)
    }

    func testOutputValidatorStopsAfterBoundedUnreadableMediaRetries() async throws {
        let recordingURL = outputDirectory.appendingPathComponent("persistently-unreadable.mp4")
        try Data([0x01]).write(to: recordingURL)
        let mediaAttempt = ScriptedMediaValidationAttempt(
            results: Array(repeating: .failure(.unreadableMedia), count: 3)
        )
        let sleeper = RecordingValidationSleeperSpy()
        let validator = RecordingOutputValidator(
            maximumMediaValidationAttempts: 3,
            retryDelay: .milliseconds(1),
            mediaValidationAttempt: mediaAttempt,
            sleeper: sleeper
        )

        do {
            try await validator.validateRecording(at: recordingURL)
            XCTFail("Expected persistently unreadable media to fail validation")
        } catch let error as RecordingOutputValidationError {
            XCTAssertEqual(error, .unreadableMedia)
        }

        XCTAssertEqual(mediaAttempt.attemptCount, 3)
        XCTAssertEqual(sleeper.sleepCount, 2)
    }

    func testEncodingPipelineRemovesOutputWhenNoSamplesWereCaptured() async throws {
        let pipeline = try EncodingPipeline(
            width: 16,
            height: 16,
            includesMicrophoneTrack: false,
            outputDirectory: outputDirectory,
            fileType: .mp4,
            fileExtension: "mp4",
            videoCodec: .h264,
            expectedFrameRate: 30,
            videoBitRate: 250_000,
            audioBitRate: 96_000
        )
        try pipeline.startWriting()

        do {
            _ = try await pipeline.finishWriting()
            XCTFail("Expected a recording with no samples to fail")
        } catch let error as EncodingPipelineError {
            XCTAssertEqual(error, .noMediaSamples)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: pipeline.temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pipeline.outputURL.path))
    }

    func testRecoveryDeletesExactEmptyArtifactsAndLeavesUnrelatedFilesUntouched() async throws {
        let emptyTemporaryURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-51.recording.mp4"
        )
        let emptySidecarURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-52.recording.mp4.sb-214a911e-va0Yiv"
        )
        let unrelatedURL = outputDirectory.appendingPathComponent("Vacation.recording.mp4.sb-user-file")
        XCTAssertTrue(FileManager.default.createFile(atPath: emptyTemporaryURL.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: emptySidecarURL.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: unrelatedURL.path, contents: Data()))

        let coordinator = makeCoordinator(validatorAcceptsMedia: false)
        await coordinator.recoverOrphanedRecordings()

        XCTAssertEqual(coordinator.discardedArtifactCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyTemporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptySidecarURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(coordinator.recoveredFiles.isEmpty)
        XCTAssertTrue(coordinator.orphanedTempFiles.isEmpty)
        XCTAssertNotNil(coordinator.warningMessage)
    }

    func testRecoveryDoesNotScanOrDeleteArtifactsWhileCoordinatorIsActive() async throws {
        let activeTemporaryURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-51.recording.mp4"
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: activeTemporaryURL.path, contents: Data()))

        let coordinator = makeCoordinator(validatorAcceptsMedia: false)
        let recoveredSentinel = outputDirectory.appendingPathComponent("recovered-sentinel.mov")
        let orphanedSentinel = outputDirectory.appendingPathComponent("orphaned-sentinel.mov")
        coordinator.recoveredFiles = [recoveredSentinel]
        coordinator.orphanedTempFiles = [orphanedSentinel]
        coordinator.discardedArtifactCount = 7

        for activeState in [
            RecordingCoordinatorState.preparing,
            .recording,
            .stopping,
        ] {
            coordinator.state = activeState
            await coordinator.recoverOrphanedRecordings()

            XCTAssertTrue(FileManager.default.fileExists(atPath: activeTemporaryURL.path))
            XCTAssertEqual(coordinator.discardedArtifactCount, 7)
            XCTAssertEqual(coordinator.recoveredFiles, [recoveredSentinel])
            XCTAssertEqual(coordinator.orphanedTempFiles, [orphanedSentinel])
        }
    }

    func testRecoveryMovesValidatedTemporaryRecordingToFinalName() async throws {
        let temporaryURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-51.recording.mov"
        )
        let finalURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-51.mov"
        )
        try Data([0x01]).write(to: temporaryURL)

        let coordinator = makeCoordinator(validatorAcceptsMedia: true)
        await coordinator.recoverOrphanedRecordings()

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(coordinator.recoveredFiles, [finalURL])
        XCTAssertTrue(coordinator.orphanedTempFiles.isEmpty)
    }

    func testRecoveryPreservesInvalidNonemptyManagedArtifactsForExplicitAction() async throws {
        let temporaryURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-51.recording.mp4"
        )
        let sidecarURL = outputDirectory.appendingPathComponent(
            "Recording_2026-07-16_23-19-52.recording.mp4.sb-214a911e-va0Yiv"
        )
        try Data([0x01]).write(to: temporaryURL)
        try Data([0x02]).write(to: sidecarURL)

        let coordinator = makeCoordinator(validatorAcceptsMedia: false)
        await coordinator.recoverOrphanedRecordings()

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertEqual(
            Set(coordinator.orphanedTempFiles.map(\.lastPathComponent)),
            Set([temporaryURL.lastPathComponent, sidecarURL.lastPathComponent])
        )
        XCTAssertTrue(coordinator.recoveredFiles.isEmpty)
        XCTAssertEqual(coordinator.discardedArtifactCount, 0)
    }

    func testExplicitDeleteRefusesUnrelatedUserFile() throws {
        let unrelatedURL = outputDirectory.appendingPathComponent("Vacation.mp4")
        try Data([0x01]).write(to: unrelatedURL)

        let coordinator = makeCoordinator(validatorAcceptsMedia: true)
        coordinator.deleteOrphanedRecording(unrelatedURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertEqual(coordinator.errorMessage, "Koji refused to delete a file it did not create.")
    }

    private func makeCoordinator(validatorAcceptsMedia: Bool) -> RecordingCoordinator {
        let preferences = Preferences(defaults: defaults)
        preferences.outputDirectory = outputDirectory

        return RecordingCoordinator(
            recordingState: RecordingState(),
            permissionsState: PermissionsState(),
            preferences: preferences,
            notificationManager: NotificationManager(),
            microphoneDiscovery: RecordingArtifactMicrophoneDiscoveryStub(),
            recordingOutputValidator: RecordingOutputValidatorStub(acceptsMedia: validatorAcceptsMedia)
        )
    }
}

private struct RecordingOutputValidatorStub: RecordingOutputValidating {
    let acceptsMedia: Bool

    func validateRecording(at url: URL) async throws {
        if !acceptsMedia {
            throw RecordingOutputValidationError.unreadableMedia
        }
    }
}

private final class ScriptedMediaValidationAttempt: RecordingMediaValidationAttempting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Void, RecordingOutputValidationError>]
    private var storedAttemptCount = 0

    var attemptCount: Int {
        lock.withLock { storedAttemptCount }
    }

    init(results: [Result<Void, RecordingOutputValidationError>]) {
        self.results = results
    }

    func validateMedia(at url: URL) async throws {
        let result = lock.withLock {
            storedAttemptCount += 1
            return results.isEmpty ? .success(()) : results.removeFirst()
        }
        try result.get()
    }
}

private final class RecordingValidationSleeperSpy: RecordingValidationSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSleepCount = 0

    var sleepCount: Int {
        lock.withLock { storedSleepCount }
    }

    func sleep(for duration: Duration) async throws {
        lock.withLock {
            storedSleepCount += 1
        }
    }
}

@MainActor
private final class RecordingArtifactMicrophoneDiscoveryStub: MicrophoneDeviceDiscovery {
    func currentSnapshot() throws -> MicrophoneDiscoverySnapshot {
        MicrophoneDiscoverySnapshot(microphones: [], defaultMicrophoneID: nil)
    }

    func startMonitoring(_ onChange: @escaping @MainActor () -> Void) {}
    func stopMonitoring() {}
}
