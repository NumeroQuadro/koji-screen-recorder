import AppKit
import XCTest
@testable import Koji

@MainActor
final class PopoverDismissalControllerTests: XCTestCase {
    func testLocalClickPolicyKeepsPopoverAndStatusItemInteractionsOpen() {
        let popoverWindow = NSWindow()
        let popoverChildWindow = NSWindow()
        let statusItemWindow = NSWindow()
        popoverWindow.addChildWindow(popoverChildWindow, ordered: .above)

        XCTAssertFalse(
            PopoverDismissalPolicy.shouldDismissLocalClick(
                eventWindow: popoverWindow,
                popoverWindow: popoverWindow,
                statusItemWindow: statusItemWindow
            )
        )
        XCTAssertFalse(
            PopoverDismissalPolicy.shouldDismissLocalClick(
                eventWindow: popoverChildWindow,
                popoverWindow: popoverWindow,
                statusItemWindow: statusItemWindow
            )
        )
        XCTAssertFalse(
            PopoverDismissalPolicy.shouldDismissLocalClick(
                eventWindow: statusItemWindow,
                popoverWindow: popoverWindow,
                statusItemWindow: statusItemWindow
            )
        )
    }

    func testLocalClickPolicyDismissesForOtherAppWindowsAndWindowlessClicks() {
        let popoverWindow = NSWindow()
        let statusItemWindow = NSWindow()
        let settingsWindow = NSWindow()

        XCTAssertTrue(
            PopoverDismissalPolicy.shouldDismissLocalClick(
                eventWindow: settingsWindow,
                popoverWindow: popoverWindow,
                statusItemWindow: statusItemWindow
            )
        )
        XCTAssertTrue(
            PopoverDismissalPolicy.shouldDismissLocalClick(
                eventWindow: nil,
                popoverWindow: popoverWindow,
                statusItemWindow: statusItemWindow
            )
        )
    }

    func testLocalClickPolicyPreservesTemporaryPickerAndMenuWindows() {
        let menuWindow = NSWindow()
        menuWindow.level = .popUpMenu

        XCTAssertFalse(
            PopoverDismissalPolicy.shouldDismissLocalClick(
                eventWindow: menuWindow,
                popoverWindow: NSWindow(),
                statusItemWindow: NSWindow()
            )
        )
    }

    func testEscapePolicyDismissesUnlessAControlOrMenuNeedsEscape() {
        let popoverWindow = NSWindow()
        let menuWindow = NSWindow()
        menuWindow.level = .popUpMenu

        XCTAssertTrue(
            PopoverDismissalPolicy.shouldDismissEscape(
                keyCode: 53,
                eventWindow: popoverWindow,
                popoverWindow: popoverWindow,
                firstResponder: nil
            )
        )
        XCTAssertFalse(
            PopoverDismissalPolicy.shouldDismissEscape(
                keyCode: 36,
                eventWindow: popoverWindow,
                popoverWindow: popoverWindow,
                firstResponder: nil
            )
        )
        XCTAssertFalse(
            PopoverDismissalPolicy.shouldDismissEscape(
                keyCode: 53,
                eventWindow: popoverWindow,
                popoverWindow: popoverWindow,
                firstResponder: NSTextView()
            )
        )
        XCTAssertFalse(
            PopoverDismissalPolicy.shouldDismissEscape(
                keyCode: 53,
                eventWindow: menuWindow,
                popoverWindow: popoverWindow,
                firstResponder: nil
            )
        )
    }

    func testControllerScopesMonitorsToPopoverLifetimeAndDoesNotSwallowClicks() {
        let eventMonitor = TestPopoverMouseEventMonitor()
        let popoverWindow = NSWindow()
        let statusItemWindow = NSWindow()
        var dismissalCount = 0
        let controller = PopoverDismissalController(
            eventMonitor: eventMonitor,
            popoverWindow: { popoverWindow },
            statusItemWindow: { statusItemWindow },
            dismiss: { dismissalCount += 1 }
        )

        controller.start()
        controller.start()

        XCTAssertEqual(eventMonitor.localInstallCount, 1)
        XCTAssertEqual(eventMonitor.globalInstallCount, 1)
        XCTAssertEqual(eventMonitor.localKeyInstallCount, 1)

        eventMonitor.sendLocalMouseDown(in: popoverWindow)
        eventMonitor.sendLocalMouseDown(in: statusItemWindow)
        XCTAssertEqual(dismissalCount, 0)

        eventMonitor.sendLocalMouseDown(in: NSWindow())
        eventMonitor.sendGlobalMouseDown()
        XCTAssertEqual(dismissalCount, 2)

        XCTAssertFalse(eventMonitor.sendLocalKeyDown(keyCode: 36, in: popoverWindow))
        XCTAssertTrue(eventMonitor.sendLocalKeyDown(keyCode: 53, in: popoverWindow))
        XCTAssertEqual(dismissalCount, 3)

        controller.stop()
        controller.stop()

        XCTAssertEqual(eventMonitor.removalCount, 3)
        XCTAssertNil(eventMonitor.localHandler)
        XCTAssertNil(eventMonitor.globalHandler)
        XCTAssertNil(eventMonitor.localKeyHandler)
    }
}

@MainActor
private final class TestPopoverMouseEventMonitor: PopoverEventMonitoring {
    private let localToken = NSObject()
    private let globalToken = NSObject()
    private let localKeyToken = NSObject()

    private(set) var localInstallCount = 0
    private(set) var globalInstallCount = 0
    private(set) var localKeyInstallCount = 0
    private(set) var removalCount = 0
    private(set) var localHandler: ((NSWindow?) -> Void)?
    private(set) var globalHandler: (() -> Void)?
    private(set) var localKeyHandler: ((UInt16, NSWindow?) -> Bool)?

    func addLocalMouseDownMonitor(_ handler: @escaping (NSWindow?) -> Void) -> Any? {
        localInstallCount += 1
        localHandler = handler
        return localToken
    }

    func addGlobalMouseDownMonitor(_ handler: @escaping () -> Void) -> Any? {
        globalInstallCount += 1
        globalHandler = handler
        return globalToken
    }

    func addLocalKeyDownMonitor(
        _ handler: @escaping (_ keyCode: UInt16, _ eventWindow: NSWindow?) -> Bool
    ) -> Any? {
        localKeyInstallCount += 1
        localKeyHandler = handler
        return localKeyToken
    }

    func removeMonitor(_ monitor: Any) {
        removalCount += 1
        let object = monitor as AnyObject
        if object === localToken {
            localHandler = nil
        } else if object === globalToken {
            globalHandler = nil
        } else if object === localKeyToken {
            localKeyHandler = nil
        }
    }

    func sendLocalMouseDown(in window: NSWindow?) {
        localHandler?(window)
    }

    func sendGlobalMouseDown() {
        globalHandler?()
    }

    func sendLocalKeyDown(keyCode: UInt16, in window: NSWindow?) -> Bool {
        localKeyHandler?(keyCode, window) ?? false
    }
}
