import Foundation
import XCTest
@testable import Koji

final class RecordingOutputRepositoryTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUp() {
        super.setUp()
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KojiOutputRepositoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outputDirectory)
        outputDirectory = nil
        super.tearDown()
    }

    func testDestinationPreservesRecordingNamingAndTemporaryMarker() throws {
        let repository = makeRepository()
        let destination = try repository.makeDestination(
            outputDirectory: outputDirectory,
            fileExtension: "mp4"
        )

        XCTAssertEqual(destination.outputURL.lastPathComponent, "Recording_1970-01-01_00-00-00.mp4")
        XCTAssertEqual(
            destination.temporaryURL.lastPathComponent,
            "Recording_1970-01-01_00-00-00.recording.mp4"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDirectory.path))
    }

    func testFinalizeMovesTemporaryFileAndAddsCollisionSuffix() throws {
        let repository = makeRepository()
        let destination = try repository.makeDestination(
            outputDirectory: outputDirectory,
            fileExtension: "mov"
        )
        try Data([0x01]).write(to: destination.outputURL)
        try Data([0x02]).write(to: destination.temporaryURL)

        let finalizedURL = try repository.finalize(destination)

        XCTAssertEqual(finalizedURL.lastPathComponent, "Recording_1970-01-01_00-00-00_1.mov")
        XCTAssertEqual(try Data(contentsOf: destination.outputURL), Data([0x01]))
        XCTAssertEqual(try Data(contentsOf: finalizedURL), Data([0x02]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.temporaryURL.path))
    }

    func testDiscardRemovesOnlyManagedActiveTemporaryFile() throws {
        let repository = makeRepository()
        let managed = try repository.makeDestination(
            outputDirectory: outputDirectory,
            fileExtension: "mp4"
        )
        try Data([0x01]).write(to: managed.temporaryURL)
        XCTAssertTrue(repository.discardTemporary(managed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.temporaryURL.path))

        let unrelated = RecordingOutputDestination(
            outputURL: outputDirectory.appendingPathComponent("Vacation.mp4"),
            temporaryURL: outputDirectory.appendingPathComponent("Vacation.recording.mp4")
        )
        try Data([0x02]).write(to: unrelated.temporaryURL)
        XCTAssertFalse(repository.discardTemporary(unrelated))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.temporaryURL.path))
    }

    func testFinalizeRejectsMissingOrUnmanagedTemporaryFiles() throws {
        let repository = makeRepository()
        let managed = try repository.makeDestination(
            outputDirectory: outputDirectory,
            fileExtension: "mp4"
        )
        XCTAssertThrowsError(try repository.finalize(managed)) { error in
            XCTAssertEqual(error as? RecordingOutputRepositoryError, .missingTemporaryFile)
        }

        let unrelated = RecordingOutputDestination(
            outputURL: outputDirectory.appendingPathComponent("Vacation.mp4"),
            temporaryURL: outputDirectory.appendingPathComponent("Vacation.recording.mp4")
        )
        try Data([0x01]).write(to: unrelated.temporaryURL)
        XCTAssertThrowsError(try repository.finalize(unrelated)) { error in
            XCTAssertEqual(error as? RecordingOutputRepositoryError, .invalidDestination)
        }
    }

    private func makeRepository() -> RecordingOutputRepository {
        RecordingOutputRepository(
            dateProvider: { Date(timeIntervalSince1970: 0) },
            timeZone: TimeZone(secondsFromGMT: 0)
        )
    }
}
