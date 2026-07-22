import AppKit

@MainActor
protocol PopoverEventMonitoring {
    func addLocalMouseDownMonitor(_ handler: @escaping (NSWindow?) -> Void) -> Any?
    func addGlobalMouseDownMonitor(_ handler: @escaping () -> Void) -> Any?
    func addLocalKeyDownMonitor(
        _ handler: @escaping (_ keyCode: UInt16, _ eventWindow: NSWindow?) -> Bool
    ) -> Any?
    func removeMonitor(_ monitor: Any)
}

@MainActor
struct AppKitPopoverEventMonitor: PopoverEventMonitoring {
    private static let mouseDownEvents: NSEvent.EventTypeMask = [
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
    ]

    func addLocalMouseDownMonitor(_ handler: @escaping (NSWindow?) -> Void) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: Self.mouseDownEvents) { event in
            handler(event.window)
            return event
        }
    }

    func addGlobalMouseDownMonitor(_ handler: @escaping () -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: Self.mouseDownEvents) { _ in
            handler()
        }
    }

    func addLocalKeyDownMonitor(
        _ handler: @escaping (_ keyCode: UInt16, _ eventWindow: NSWindow?) -> Bool
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event.keyCode, event.window) ? nil : event
        }
    }

    func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}

@MainActor
final class PopoverDismissalController {
    private let eventMonitor: any PopoverEventMonitoring
    private let popoverWindow: () -> NSWindow?
    private let statusItemWindow: () -> NSWindow?
    private let dismiss: () -> Void

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?

    init(
        eventMonitor: any PopoverEventMonitoring,
        popoverWindow: @escaping () -> NSWindow?,
        statusItemWindow: @escaping () -> NSWindow?,
        dismiss: @escaping () -> Void
    ) {
        self.eventMonitor = eventMonitor
        self.popoverWindow = popoverWindow
        self.statusItemWindow = statusItemWindow
        self.dismiss = dismiss
    }

    func start() {
        if localMouseMonitor == nil {
            localMouseMonitor = eventMonitor.addLocalMouseDownMonitor { [weak self] eventWindow in
                guard let self else { return }
                if PopoverDismissalPolicy.shouldDismissLocalClick(
                    eventWindow: eventWindow,
                    popoverWindow: self.popoverWindow(),
                    statusItemWindow: self.statusItemWindow()
                ) {
                    self.dismiss()
                }
            }
        }

        if globalMouseMonitor == nil {
            globalMouseMonitor = eventMonitor.addGlobalMouseDownMonitor { [weak self] in
                self?.dismiss()
            }
        }

        if localKeyMonitor == nil {
            localKeyMonitor = eventMonitor.addLocalKeyDownMonitor { [weak self] keyCode, eventWindow in
                guard let self else { return false }
                let popoverWindow = self.popoverWindow()
                guard PopoverDismissalPolicy.shouldDismissEscape(
                    keyCode: keyCode,
                    eventWindow: eventWindow,
                    popoverWindow: popoverWindow,
                    firstResponder: popoverWindow?.firstResponder
                ) else {
                    return false
                }

                self.dismiss()
                return true
            }
        }
    }

    func stop() {
        if let localMouseMonitor {
            eventMonitor.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        if let globalMouseMonitor {
            eventMonitor.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }

        if let localKeyMonitor {
            eventMonitor.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}

@MainActor
enum PopoverDismissalPolicy {
    private static let escapeKeyCode: UInt16 = 53

    static func shouldDismissLocalClick(
        eventWindow: NSWindow?,
        popoverWindow: NSWindow?,
        statusItemWindow: NSWindow?
    ) -> Bool {
        guard let eventWindow else { return true }

        if isSameWindowOrDescendant(eventWindow, of: popoverWindow)
            || isSameWindowOrDescendant(eventWindow, of: statusItemWindow) {
            return false
        }

        // SwiftUI pickers and menus use temporary high-level AppKit windows.
        // Treat clicks in those windows as interaction with the popover control.
        if eventWindow.level >= .popUpMenu {
            return false
        }

        return true
    }

    static func shouldDismissEscape(
        keyCode: UInt16,
        eventWindow: NSWindow?,
        popoverWindow: NSWindow?,
        firstResponder: NSResponder?
    ) -> Bool {
        guard keyCode == escapeKeyCode else { return false }

        if let eventWindow,
           !isSameWindowOrDescendant(eventWindow, of: popoverWindow),
           eventWindow.level >= .popUpMenu {
            return false
        }

        if firstResponder is NSTextView || firstResponder is NSTextField {
            return false
        }

        return true
    }

    private static func isSameWindowOrDescendant(
        _ candidate: NSWindow,
        of ancestor: NSWindow?
    ) -> Bool {
        guard let ancestor else { return false }

        var currentWindow: NSWindow? = candidate
        while let current = currentWindow {
            if current === ancestor {
                return true
            }
            currentWindow = current.parent
        }

        return false
    }
}
