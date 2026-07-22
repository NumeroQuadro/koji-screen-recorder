import Foundation
import Observation

@MainActor
@Observable
final class RecordingState {
    var isRecording: Bool = false
    var elapsedTime: TimeInterval = 0
    var currentFile: URL?
    var currentFileSizeBytes: Int64 = 0
    var lastSavedFile: URL?

    var formattedElapsedTime: String {
        let totalSeconds = Int(elapsedTime.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: currentFileSizeBytes, countStyle: .file)
    }
}
