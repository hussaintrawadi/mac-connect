import Foundation
import UserNotifications
import os

final class NotificationFeature: NSObject, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "Notifications")
    var onSendAction: ((ABEnvelope) -> Void)?

    override init() {
        super.init()
        requestPermission()
        UNUserNotificationCenter.current().delegate = self
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                self.logger.info("Notification permission granted")
            } else {
                self.logger.warning("Notification permission denied: \(error?.localizedDescription ?? "none")")
            }
        }
    }

    func handleNotification(_ event: ABNotificationEvent) {
        let content = UNMutableNotificationContent()
        content.title = "\(event.appName) — \(event.title)"
        content.body = event.body
        content.sound = .default
        // Standard priority — lets macOS Focus/DND filter these like any other app.
        content.interruptionLevel = .active
        content.categoryIdentifier = event.hasReplyAction_p ? "REPLY_CATEGORY" : "DEFAULT_CATEGORY"
        content.userInfo = [
            "notificationId": event.notificationID,
            "appPackage": event.appPackage,
            "hasReply": event.hasReplyAction_p
        ]

        // Attach the originating phone-app's icon so it shows on the notification.
        if !event.iconPng.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacConnectNotifIcons", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(UUID().uuidString).png")
            if (try? event.iconPng.write(to: url)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "appIcon", url: url, options: nil) {
                content.attachments = [attachment]
            }
        }

        let request = UNNotificationRequest(
            identifier: event.notificationID,
            content: content,
            trigger: nil
        )

        registerCategories()

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                self.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }

        logger.info("Displayed notification from \(event.appName): \(event.title)")
    }

    private func registerCategories() {
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY_ACTION",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply..."
        )

        let dismissAction = UNNotificationAction(
            identifier: "DISMISS_ACTION",
            title: "Dismiss",
            options: .destructive
        )

        let replyCategory = UNNotificationCategory(
            identifier: "REPLY_CATEGORY",
            actions: [replyAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        let defaultCategory = UNNotificationCategory(
            identifier: "DEFAULT_CATEGORY",
            actions: [dismissAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([replyCategory, defaultCategory])
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let notificationId = userInfo["notificationId"] as? String else {
            completionHandler()
            return
        }

        var action = ABNotificationAction()
        action.notificationID = notificationId

        switch response.actionIdentifier {
        case "REPLY_ACTION":
            if let textResponse = response as? UNTextInputNotificationResponse {
                action.action = .reply
                action.replyText = textResponse.userText
                logger.info("Reply to \(notificationId): \(textResponse.userText)")
            }
        case "DISMISS_ACTION":
            action.action = .dismiss
        case UNNotificationDefaultActionIdentifier:
            return completionHandler()
        default:
            return completionHandler()
        }

        var envelope = ABEnvelope()
        envelope.notificationAction = action
        onSendAction?(envelope)

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
