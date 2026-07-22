import Foundation

struct MicrophoneOption: Identifiable, Equatable, Sendable {
    static let noneID = "none"

    let id: String
    let name: String

    var deviceID: String? {
        id == Self.noneID ? nil : id
    }

    static let none = MicrophoneOption(id: Self.noneID, name: "No Microphone (system audio only)")
}
