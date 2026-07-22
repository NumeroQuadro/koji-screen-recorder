import Foundation

enum CameraKind: String, Equatable, Sendable {
    case continuity
    case builtIn
    case external

    var title: String {
        switch self {
        case .continuity:
            "Continuity Camera"
        case .builtIn:
            "Built-in"
        case .external:
            "External"
        }
    }

    var sortOrder: Int {
        switch self {
        case .continuity:
            0
        case .builtIn:
            1
        case .external:
            2
        }
    }
}

struct CameraOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: CameraKind

    var menuTitle: String {
        "\(name) · \(kind.title)"
    }
}

enum CameraSelection: Equatable, Hashable, Sendable {
    case automatic
    case manual(deviceID: String)
}

enum CameraAccessState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
    case disconnected
}

struct CameraDiscoverySnapshot: Equatable, Sendable {
    let cameras: [CameraOption]
    let systemPreferredCameraID: String?
}
