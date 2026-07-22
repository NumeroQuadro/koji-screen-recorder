import ScreenCaptureKit

enum ContentFilter {
    static func fullScreenFilter(
        display: SCDisplay,
        excludingApplications: [SCRunningApplication],
        excludingWindows: [SCWindow]
    ) -> SCContentFilter {
        if !excludingApplications.isEmpty {
            return SCContentFilter(
                display: display,
                excludingApplications: excludingApplications,
                exceptingWindows: []
            )
        }

        return SCContentFilter(display: display, excludingWindows: excludingWindows)
    }

    static func windowFilter(window: SCWindow) -> SCContentFilter {
        SCContentFilter(desktopIndependentWindow: window)
    }

    static func appFilter(app: SCRunningApplication, display: SCDisplay) -> SCContentFilter {
        SCContentFilter(display: display, including: [app], exceptingWindows: [])
    }
}
