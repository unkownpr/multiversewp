import AppKit
import Foundation
import UserNotifications

@MainActor
public final class NotificationCenterBridge: NSObject, MessageIngestionService.Notifier, UNUserNotificationCenterDelegate {

    private let center: UNUserNotificationCenter
    private let log = AppLog.make("Notifications")

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    // Without this delegate macOS suppresses banners while MultiverseWP is the
    // foreground app — notifications silently land in Notification Center and
    // the user thinks the test action is broken.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    public func requestAuthorizationIfNeeded() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            log.info("Notification authorization granted: \(granted, privacy: .public)")
        } catch {
            log.error("Authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    public func openSystemNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.notifications",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    public func sendTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "MultiverseWP"
        content.body = "Test notification — notifications are working."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            log.error("Test deliver failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated public func deliver(account: Account, chat: Chat, message: Message) async {
        await MainActor.run { [self] in
            Task { await self.performDeliver(account: account, chat: chat, message: message) }
        }
    }

    private func performDeliver(account: Account, chat: Chat, message: Message) async {
        guard account.notificationsEnabled, !chat.isMuted else { return }
        guard message.direction == .incoming else { return }

        let content = UNMutableNotificationContent()
        content.title = chat.title
        content.subtitle = account.displayName
        content.body = message.body ?? "[media message]"
        content.sound = .default
        content.threadIdentifier = "\(account.id.uuidString)-\(chat.id)"
        content.userInfo = [
            "account_id": account.id.uuidString,
            "chat_id": chat.id,
            "message_id": message.id
        ]

        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            log.error("Delivery failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
