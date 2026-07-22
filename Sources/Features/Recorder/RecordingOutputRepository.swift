import Foundation

struct RecordingOutputDestination: Equatable, Sendable {
    let outputURL: URL
    let temporaryURL: URL
}

enum RecordingOutputRepositoryError: Error, Equatable {
    case invalidDestination
    case missingTemporaryFile
}

struct RecordingOutputRepository {
    private let fileManager: FileManager
    private let dateProvider: () -> Date
    private let timeZone: TimeZone?

    init(
        fileManager: FileManager = .default,
        dateProvider: @escaping () -> Date = { Date() },
        timeZone: TimeZone? = nil
    ) {
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.timeZone = timeZone
    }

    func makeDestination(
        outputDirectory: URL,
        fileExtension: String
    ) throws -> RecordingOutputDestination {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let timeZone {
            formatter.timeZone = timeZone
        }
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let baseName = "Recording_\(formatter.string(from: dateProvider()))"
        return RecordingOutputDestination(
            outputURL: outputDirectory
                .appendingPathComponent(baseName)
                .appendingPathExtension(fileExtension),
            temporaryURL: outputDirectory
                .appendingPathComponent("\(baseName).recording")
                .appendingPathExtension(fileExtension)
        )
    }

    func finalize(_ destination: RecordingOutputDestination) throws -> URL {
        guard isManaged(destination) else {
            throw RecordingOutputRepositoryError.invalidDestination
        }
        guard fileManager.fileExists(atPath: destination.temporaryURL.path) else {
            throw RecordingOutputRepositoryError.missingTemporaryFile
        }

        let finalURL = uniqueURL(for: destination.outputURL)
        try fileManager.moveItem(at: destination.temporaryURL, to: finalURL)
        return finalURL
    }

    @discardableResult
    func discardTemporary(_ destination: RecordingOutputDestination) -> Bool {
        guard isManaged(destination), fileManager.fileExists(atPath: destination.temporaryURL.path) else {
            return false
        }

        do {
            try fileManager.removeItem(at: destination.temporaryURL)
            return true
        } catch {
            return false
        }
    }

    private func isManaged(_ destination: RecordingOutputDestination) -> Bool {
        let outputDirectory = destination.outputURL.deletingLastPathComponent()
        guard
            destination.temporaryURL.deletingLastPathComponent().standardizedFileURL
                == outputDirectory.standardizedFileURL,
            case let .temporaryRecording(finalURL)? = RecordingArtifactPolicy.kind(
                for: destination.temporaryURL,
                in: outputDirectory
            )
        else {
            return false
        }
        return finalURL.standardizedFileURL == destination.outputURL.standardizedFileURL
    }

    private func uniqueURL(for url: URL) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1

        while true {
            let candidate = directory
                .appendingPathComponent("\(baseName)_\(counter)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }
}
