import SwiftUI

/// Central brand constants for Kōji.
enum Brand {
    /// Display name of the application.
    static let appName = "Kōji"

    /// Bundle identifier.
    static let bundleID = "com.koji.screenrecorder"

    /// Kōji brand red (#E63946).
    static let accentColor = Color(red: 0xE6 / 255.0, green: 0x39 / 255.0, blue: 0x46 / 255.0)

    /// NSColor version of the brand red for AppKit usage.
    static let accentNSColor = NSColor(red: 0xE6 / 255.0, green: 0x39 / 255.0, blue: 0x46 / 255.0, alpha: 1.0)

    /// Dark background color (#1A1A2E) used in icon and UI accents.
    static let darkBackground = Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x2E / 255.0)

    /// Current app version string from the bundle, falling back to "1.0.0".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// Current build number from the bundle.
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Full version string, e.g. "1.0.0 (1)".
    static var fullVersion: String {
        "\(version) (\(buildNumber))"
    }
}
