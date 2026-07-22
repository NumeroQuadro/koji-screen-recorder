import AppKit
import CoreGraphics
import ScreenCaptureKit

struct CapturePixelSize: Equatable, Sendable {
    let width: Int
    let height: Int
}

enum CaptureTargetSelection: Equatable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case application(bundleIdentifier: String, displayID: CGDirectDisplayID)

    var token: CaptureSourceToken {
        switch self {
        case let .display(displayID):
            .display(displayID)
        case let .window(windowID):
            .window(windowID)
        case let .application(bundleIdentifier, _):
            .application(bundleIdentifier: bundleIdentifier)
        }
    }

    var scalesToFit: Bool {
        if case .window = self {
            return true
        }
        return false
    }
}

struct CaptureTargetInventory: Equatable, Sendable {
    let displayIDs: [CGDirectDisplayID]
    let windowIDs: Set<CGWindowID>
    let applicationBundleIdentifiers: Set<String>
}

enum CaptureTargetSelectionPolicy {
    static func resolve(
        selectedToken: CaptureSourceToken?,
        preferredDisplayID: CGDirectDisplayID?,
        primaryDisplayID: CGDirectDisplayID?,
        inventory: CaptureTargetInventory
    ) -> CaptureTargetSelection? {
        if let selectedToken {
            switch selectedToken {
            case let .display(displayID):
                if inventory.displayIDs.contains(displayID) {
                    return .display(displayID)
                }
            case let .window(windowID):
                if inventory.windowIDs.contains(windowID) {
                    return .window(windowID)
                }
            case let .application(bundleIdentifier):
                if inventory.applicationBundleIdentifiers.contains(bundleIdentifier),
                   let displayID = validDisplayID(primaryDisplayID, in: inventory) ?? inventory.displayIDs.first
                {
                    return .application(bundleIdentifier: bundleIdentifier, displayID: displayID)
                }
            }
        }

        let fallbackDisplayID = validDisplayID(preferredDisplayID, in: inventory)
            ?? validDisplayID(primaryDisplayID, in: inventory)
            ?? inventory.displayIDs.first
        return fallbackDisplayID.map(CaptureTargetSelection.display)
    }

    private static func validDisplayID(
        _ displayID: CGDirectDisplayID?,
        in inventory: CaptureTargetInventory
    ) -> CGDirectDisplayID? {
        guard let displayID, inventory.displayIDs.contains(displayID) else { return nil }
        return displayID
    }
}

struct ResolvedCaptureTarget {
    let filter: SCContentFilter
    let token: CaptureSourceToken
    let scalesToFit: Bool
    let pixelSize: CapturePixelSize
    let selectedDisplayGeometry: SelectedDisplayCaptureGeometry?
}

struct SelectedDisplayCaptureGeometry: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frameInScreenPoints: CGRect
    let pointPixelScale: CGFloat
}

enum CaptureIsolationPolicy {
    static func isCurrentProcess(
        applicationProcessID: pid_t,
        applicationBundleIdentifier: String,
        currentProcessID: pid_t,
        currentBundleIdentifier: String?
    ) -> Bool {
        if applicationProcessID == currentProcessID {
            return true
        }

        guard let currentBundleIdentifier else { return false }
        return applicationBundleIdentifier == currentBundleIdentifier
    }
}

struct CaptureTargetResolver {
    func resolve(
        selectedToken: CaptureSourceToken?,
        preferredDisplayID: CGDirectDisplayID?,
        content: SCShareableContent
    ) -> ResolvedCaptureTarget? {
        let inventory = CaptureTargetInventory(
            displayIDs: content.displays.map(\.displayID),
            windowIDs: Set(content.windows.map(\.windowID)),
            applicationBundleIdentifiers: Set(content.applications.map(\.bundleIdentifier))
        )
        guard let selection = CaptureTargetSelectionPolicy.resolve(
            selectedToken: selectedToken,
            preferredDisplayID: preferredDisplayID,
            primaryDisplayID: Self.primaryDisplayID(from: content.displays),
            inventory: inventory
        ) else {
            return nil
        }

        let filter: SCContentFilter
        var selectedDisplayGeometry: SelectedDisplayCaptureGeometry?
        switch selection {
        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let currentProcessID = ProcessInfo.processInfo.processIdentifier
            let currentBundleIdentifier = Bundle.main.bundleIdentifier
            let excludedApplications = content.applications.filter { application in
                CaptureIsolationPolicy.isCurrentProcess(
                    applicationProcessID: application.processID,
                    applicationBundleIdentifier: application.bundleIdentifier,
                    currentProcessID: currentProcessID,
                    currentBundleIdentifier: currentBundleIdentifier
                )
            }
            let excludedWindows = content.windows.filter { window in
                guard let application = window.owningApplication else { return false }
                return CaptureIsolationPolicy.isCurrentProcess(
                    applicationProcessID: application.processID,
                    applicationBundleIdentifier: application.bundleIdentifier,
                    currentProcessID: currentProcessID,
                    currentBundleIdentifier: currentBundleIdentifier
                )
            }
            filter = ContentFilter.fullScreenFilter(
                display: display,
                excludingApplications: excludedApplications,
                excludingWindows: excludedWindows
            )
        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            filter = ContentFilter.windowFilter(window: window)
        case let .application(bundleIdentifier, displayID):
            guard
                let application = content.applications.first(where: { $0.bundleIdentifier == bundleIdentifier }),
                let display = content.displays.first(where: { $0.displayID == displayID })
            else {
                return nil
            }
            filter = ContentFilter.appFilter(app: application, display: display)
        }

        let filterInfo = SCShareableContent.info(for: filter)
        if case let .display(displayID) = selection,
           let display = content.displays.first(where: { $0.displayID == displayID }) {
            selectedDisplayGeometry = SelectedDisplayCaptureGeometry(
                displayID: displayID,
                frameInScreenPoints: display.frame,
                pointPixelScale: CGFloat(filterInfo.pointPixelScale)
            )
        }
        return ResolvedCaptureTarget(
            filter: filter,
            token: selection.token,
            scalesToFit: selection.scalesToFit,
            pixelSize: Self.pixelSize(
                contentRect: filterInfo.contentRect,
                pointPixelScale: CGFloat(filterInfo.pointPixelScale)
            ),
            selectedDisplayGeometry: selectedDisplayGeometry
        )
    }

    static func primaryDisplayID(from displays: [SCDisplay]) -> CGDirectDisplayID? {
        guard !displays.isEmpty else { return nil }
        guard
            let mainScreen = NSScreen.main,
            let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return displays.first?.displayID
        }

        let mainDisplayID = CGDirectDisplayID(screenNumber.uint32Value)
        return displays.first(where: { $0.displayID == mainDisplayID })?.displayID
            ?? displays.first?.displayID
    }

    static func pixelSize(contentRect: CGRect, pointPixelScale: CGFloat) -> CapturePixelSize {
        CapturePixelSize(
            width: max(1, Int((contentRect.width * pointPixelScale).rounded())),
            height: max(1, Int((contentRect.height * pointPixelScale).rounded()))
        )
    }
}
