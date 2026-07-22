import AVFoundation
import Foundation
import OSLog

enum RecordingOutputValidationError: Error, Equatable {
    case unreadableFile
    case unsafeFileType
    case emptyFile
    case unreadableMedia
    case missingVideoTrack
}

protocol RecordingOutputValidating: Sendable {
    func validateRecording(at url: URL) async throws
}

protocol RecordingMediaValidationAttempting: Sendable {
    func validateMedia(at url: URL) async throws
}

protocol RecordingValidationSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

private struct AVFoundationRecordingMediaValidationAttempt: RecordingMediaValidationAttempting {
    func validateMedia(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw RecordingOutputValidationError.unreadableMedia
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw RecordingOutputValidationError.missingVideoTrack
        }
    }
}

private struct TaskRecordingValidationSleeper: RecordingValidationSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct RecordingOutputValidator: RecordingOutputValidating {
    private static let logger = Logger(
        subsystem: "com.koji.screenrecorder",
        category: "RecordingValidation"
    )

    private let maximumMediaValidationAttempts: Int
    private let retryDelay: Duration
    private let mediaValidationAttempt: any RecordingMediaValidationAttempting
    private let sleeper: any RecordingValidationSleeping

    init(
        maximumMediaValidationAttempts: Int = 4,
        retryDelay: Duration = .milliseconds(150),
        mediaValidationAttempt: any RecordingMediaValidationAttempting = AVFoundationRecordingMediaValidationAttempt(),
        sleeper: any RecordingValidationSleeping = TaskRecordingValidationSleeper()
    ) {
        precondition(maximumMediaValidationAttempts > 0)
        self.maximumMediaValidationAttempts = maximumMediaValidationAttempts
        self.retryDelay = retryDelay
        self.mediaValidationAttempt = mediaValidationAttempt
        self.sleeper = sleeper
    }

    func validateRecording(at url: URL) async throws {
        let fileSize: Int64
        do {
            fileSize = try RecordingArtifactPolicy.regularFileSize(at: url)
        } catch let error as RecordingOutputValidationError {
            throw error
        } catch {
            throw RecordingOutputValidationError.unreadableFile
        }

        guard fileSize > 0 else {
            throw RecordingOutputValidationError.emptyFile
        }
        Self.logger.info(
            "result=checked stage=filesystem sizeBytes=\(fileSize, privacy: .public)"
        )

        for attempt in 1...maximumMediaValidationAttempts {
            do {
                try await mediaValidationAttempt.validateMedia(at: url)
                if attempt > 1 {
                    Self.logger.info(
                        "result=recovered reason=unreadableMedia attempt=\(attempt, privacy: .public)"
                    )
                }
                return
            } catch let error as RecordingOutputValidationError {
                let shouldRetry = error == .unreadableMedia
                    && attempt < maximumMediaValidationAttempts
                if shouldRetry {
                    Self.logger.info(
                        "result=retry reason=\(Self.logReason(error), privacy: .public) attempt=\(attempt, privacy: .public)"
                    )
                    try await sleeper.sleep(for: retryDelay)
                    continue
                }
                Self.logger.error(
                    "result=failed reason=\(Self.logReason(error), privacy: .public) attempt=\(attempt, privacy: .public)"
                )
                throw error
            } catch {
                if attempt < maximumMediaValidationAttempts {
                    Self.logger.info(
                        "result=retry reason=unreadableMedia attempt=\(attempt, privacy: .public)"
                    )
                    try await sleeper.sleep(for: retryDelay)
                    continue
                }
                Self.logger.error(
                    "result=failed reason=unreadableMedia attempt=\(attempt, privacy: .public)"
                )
                throw RecordingOutputValidationError.unreadableMedia
            }
        }
    }

    private static func logReason(_ error: RecordingOutputValidationError) -> String {
        switch error {
        case .unreadableFile:
            "unreadableFile"
        case .unsafeFileType:
            "unsafeFileType"
        case .emptyFile:
            "emptyFile"
        case .unreadableMedia:
            "unreadableMedia"
        case .missingVideoTrack:
            "missingVideoTrack"
        }
    }
}

enum RecordingArtifactKind: Equatable {
    case temporaryRecording(finalURL: URL)
    case crashSidecar
}

enum RecordingArtifactPolicy {
    private static let recordingMarker = ".recording."
    private static let crashMarker = ".sb-"
    private static let supportedExtensions: Set<String> = ["mov", "mp4"]

    static func kind(for url: URL, in outputDirectory: URL) -> RecordingArtifactKind? {
        guard isDirectChild(url, of: outputDirectory) else { return nil }

        let fileName = url.lastPathComponent
        guard let components = managedNameComponents(for: fileName) else { return nil }

        if supportedExtensions.contains(components.remainder) {
            let finalURL = outputDirectory
                .appendingPathComponent(components.baseName)
                .appendingPathExtension(components.remainder)
            return .temporaryRecording(finalURL: finalURL)
        }

        for ext in supportedExtensions {
            let prefix = ext + crashMarker
            guard components.remainder.hasPrefix(prefix) else { continue }

            let suffix = components.remainder.dropFirst(prefix.count)
            guard !suffix.isEmpty, suffix.allSatisfy(isCrashSuffixCharacter) else {
                return nil
            }
            return .crashSidecar
        }

        return nil
    }

    static func regularFileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard
            let fileType = attributes[.type] as? FileAttributeType,
            fileType == .typeRegular
        else {
            throw RecordingOutputValidationError.unsafeFileType
        }
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw RecordingOutputValidationError.unreadableFile
        }
        return fileSize.int64Value
    }

    private static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }

    private static func managedNameComponents(for fileName: String) -> (baseName: String, remainder: String)? {
        guard let markerRange = fileName.range(of: recordingMarker) else { return nil }

        let baseName = String(fileName[..<markerRange.lowerBound])
        let remainder = String(fileName[markerRange.upperBound...])
        guard isGeneratedRecordingBaseName(baseName) else { return nil }
        return (baseName, remainder)
    }

    private static func isGeneratedRecordingBaseName(_ baseName: String) -> Bool {
        let prefix = "Recording_"
        guard baseName.hasPrefix(prefix) else { return false }

        let timestamp = String(baseName.dropFirst(prefix.count))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.isLenient = false

        guard let date = formatter.date(from: timestamp) else { return false }
        return formatter.string(from: date) == timestamp
    }

    private static func isCrashSuffixCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }
}
