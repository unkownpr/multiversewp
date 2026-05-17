import Foundation
import UserNotifications

@MainActor
public final class NotificationCenterBridge {

    public static let shared = NotificationCenterBridge()

    private let center = UNUserNotificationCenter.current()
    private let log = AppLog.make("Notifications")

    private init() {}

    public func requestAuthorizationIfNeeded() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            log.info("Notification authorization granted: \(granted, privacy: .public)")
        } catch {
            log.error("Authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func deliver(account: Account, chat: Chat, message: Message) async {
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

        let request = UNNotificationRequest(
            identifier: message.id,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            log.error("Delivery failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
