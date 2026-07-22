import AppKit
import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let recordingSavedCategory = "KOJI_RECORDING_SAVED"
    static let revealAction = "KOJI_REVEAL_IN_FINDER"

    private var isEnabled: Bool = false

    private var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func start() {
        guard canUseUserNotifications else {
            isEnabled = false
            print("UserNotifications disabled: Koji is not running from an .app bundle.")
            return
        }

        isEnabled = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reveal = UNNotificationAction(
            identifier: Self.revealAction,
            title: "Reveal in Finder",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: Self.recordingSavedCategory,
            actions: [reveal],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([category])

        Task {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                print("Notification authorization request failed: \(error)")
            }
        }
    }

    func postRecordingSaved(url: URL, isPartial: Bool) {
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = isPartial ? "Partial recording saved" : "Recording saved"
        content.body = url.lastPathComponent
        content.sound = .default
        content.categoryIdentifier = Self.recordingSavedCategory
        content.userInfo = [
            "filePath": url.path,
        ]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Failed to post notification: \(error)")
            }
        }
    }

    func postWarning(title: String, message: String) {
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Failed to post warning notification: \(error)")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let filePath = response.notification.request.content.userInfo["filePath"] as? String
        guard let filePath else { return }

        let url = URL(fileURLWithPath: filePath)
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
