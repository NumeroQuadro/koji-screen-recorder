import CoreGraphics
import Foundation

enum CaptureSourceToken: Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case application(bundleIdentifier: String)

    enum Kind: String {
        case display
        case window
        case application
    }

    var kind: Kind {
        switch self {
        case .display:
            .display
        case .window:
            .window
        case .application:
            .application
        }
    }

    var rawValue: String {
        switch self {
        case let .display(displayID):
            "display:\(displayID)"
        case let .window(windowID):
            "window:\(windowID)"
        case let .application(bundleIdentifier):
            "app:\(bundleIdentifier)"
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        switch parts[0] {
        case "display":
            guard let displayID = UInt32(parts[1]) else { return nil }
            self = .display(CGDirectDisplayID(displayID))
        case "window":
            guard let windowID = UInt32(parts[1]) else { return nil }
            self = .window(CGWindowID(windowID))
        case "app":
            let bundleIdentifier = parts[1]
            guard !bundleIdentifier.isEmpty else { return nil }
            self = .application(bundleIdentifier: bundleIdentifier)
        default:
            return nil
        }
    }
}

struct CaptureSourceOption: Identifiable, Equatable {
    let token: CaptureSourceToken
    let title: String
    let subtitle: String?

    var id: String { token.rawValue }
}
