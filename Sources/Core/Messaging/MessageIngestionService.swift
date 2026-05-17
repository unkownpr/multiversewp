import Foundation

@MainActor
public final class MessageIngestionService {

    public protocol Notifier: AnyObject, Sendable {
        func deliver(account: Account, chat: Chat, message: Message) async
    }

    public protocol SelectionProvider: AnyObject {
        var selectedAccountID: Account.ID? { get }
        var selectedChatID: Chat.ID? { get }
    }

    private let storage: AppStorage
    private let eventBus: EventBus
    private var notifier: Notifier?
    private weak var selection: AnyObject?
    private let log = AppLog.make("Ingestion")

    private var tasks: [Account.ID: Task<Void, Never>] = [:]

    public init(
        storage: AppStorage,
        eventBus: EventBus,
        notifier: Notifier? = nil,
        selection: (any SelectionProvider)? = nil
    ) {
        self.storage = storage
        self.eventBus = eventBus
        self.notifier = notifier
        self.selection = selection
    }

    public func attach(selection: any SelectionProvider, notifier: Notifier) {
        self.selection = selection
        self.notifier = notifier
    }

    public func subscribe(account: Account, client: WAClient) {
        tasks[account.id]?.cancel()
        // Capture the AsyncStream synchronously so the underlying subject
        // subscription is in place before the helper's next event lands.
        let stream = client.events
        tasks[account.id] = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                if Task.isCancelled { return }
                await self.handle(event: event, account: account)
            }
        }
    }

    public func unsubscribe(accountID: Account.ID) {
        tasks[accountID]?.cancel()
        tasks.removeValue(forKey: accountID)
    }

    public func stopAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func handle(event: WAClientEvent, account: Account) async {
        switch event {
        case .messageReceived(let incoming):
            await ingest(incoming: incoming, account: account)
        case .deliveryUpdate(let messageID, let status):
            await updateDelivery(messageID: messageID, status: status)
        case .contactUpdate(let contact):
            await ingest(contact: contact, account: account)
        case .connected:
            eventBus.publish(.accountConnected(account.id))
        case .disconnected:
            eventBus.publish(.accountDisconnected(account.id))
        case .error(let message):
            eventBus.publish(.error(accountID: account.id, message: message))
        default:
            break
        }
    }

    private func ingest(incoming: IncomingMessage, account: Account) async {
        let chatID = incoming.chatJID
        do {
            let existingChat = try await storage.chats.chat(id: chatID)
            let title = await resolveChatTitle(
                existing: existingChat,
                incoming: incoming,
                accountID: account.id
            )
            let chat = Chat(
                id: chatID,
                accountID: account.id,
                jid: incoming.chatJID,
                title: title,
                isGroup: incoming.isGroup,
                lastMessagePreview: messagePreview(from: incoming),
                lastMessageTimestamp: incoming.timestamp,
                unreadCount: existingChat?.unreadCount ?? 0,
                isMuted: existingChat?.isMuted ?? false,
                isPinned: existingChat?.isPinned ?? false,
                isArchived: false
            )
            try await storage.chats.upsert(chat)

            let direction: Message.Direction = incoming.isFromMe ? .outgoing : .incoming
            let kind = Message.Kind(rawValue: incoming.kind) ?? .text
            let message = Message(
                id: incoming.id,
                chatID: chatID,
                accountID: account.id,
                senderJID: incoming.senderJID,
                senderDisplayName: incoming.senderPushName,
                direction: direction,
                kind: kind,
                body: incoming.body,
                mediaID: incoming.mediaURL == nil ? nil : incoming.id,
                quotedMessageID: incoming.quotedMessageID,
                timestamp: incoming.timestamp,
                deliveryStatus: direction == .incoming ? .delivered : .sent,
                isStarred: false,
                isDeleted: false
            )
            try await storage.messages.upsert(message)

            if direction == .incoming {
                let isCurrentlyOpen = isChatCurrentlyOpen(accountID: account.id, chatID: chatID)
                if !isCurrentlyOpen {
                    try await storage.chats.incrementUnread(for: chatID, by: 1)
                    await notifier?.deliver(account: account, chat: chat, message: message)
                }
            }

            eventBus.publish(.messageReceived(message))
        } catch {
            log.error("ingest failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateDelivery(messageID: String, status: String) async {
        let parsed = Message.DeliveryStatus(rawValue: status) ?? .delivered
        do {
            try await storage.messages.updateDelivery(messageID: messageID, status: parsed)
            eventBus.publish(.messageDeliveryUpdated(messageID: messageID, status: parsed))
        } catch {
            log.error("delivery update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ingest(contact: IncomingContact, account: Account) async {
        let model = Contact(
            id: "\(account.id.uuidString):\(contact.jid)",
            accountID: account.id,
            jid: contact.jid,
            pushName: contact.pushName,
            businessName: contact.businessName,
            phoneNumber: contact.phoneNumber
        )
        do {
            try await storage.contacts.upsert(model)
            eventBus.publish(.contactUpdated(model))
            // If a 1:1 chat already exists for this JID and its title is
            // still the bare JID prefix, retitle it with the freshly-known
            // push / business name.
            if let chat = try await storage.chats.chat(id: contact.jid),
               !chat.isGroup,
               looksLikeJIDTitle(chat.title, jid: chat.jid) {
                let display = model.displayName
                if display != chat.jid, display != chat.title {
                    var renamed = chat
                    renamed.title = display
                    try await storage.chats.upsert(renamed)
                    eventBus.publish(.chatUpdated(renamed))
                }
            }
        } catch {
            log.error("contact upsert failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveChatTitle(
        existing: Chat?,
        incoming: IncomingMessage,
        accountID: Account.ID
    ) async -> String {
        // Self-chat ("Note to Self"): the WhatsApp account's own JID maps
        // to a special conversation; pull the human label from the account
        // record.
        if let account = try? await storage.accounts.allAccounts().first(where: { $0.id == accountID }),
           let ownJid = account.jid,
           jidsMatch(incoming.chatJID, ownJid) {
            return "You · Note to Self"
        }

        // If the existing title already reads as a human label, keep it.
        if let existing, !looksLikeJIDTitle(existing.title, jid: existing.jid) {
            return existing.title
        }

        // 1:1 chat: peer push name from the incoming envelope when the peer
        // is the sender.
        if !incoming.isGroup,
           !incoming.isFromMe,
           let push = incoming.senderPushName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !push.isEmpty {
            return push
        }

        // Look the peer up in the contact store (the helper's HistorySync
        // Pushname stream populates these on cold pair).
        if let contact = try? await storage.contacts.contact(jid: incoming.chatJID, accountID: accountID) {
            let display = contact.displayName
            if display != incoming.chatJID, !display.isEmpty {
                return display
            }
        }

        // Last resort — format the JID local part as a phone number.
        return defaultChatTitle(jid: incoming.chatJID, sender: incoming.senderPushName)
    }

    /// Compare two JIDs ignoring optional `:device` suffixes and server parts.
    private func jidsMatch(_ lhs: String, _ rhs: String) -> Bool {
        func canonical(_ jid: String) -> String {
            let userServer = jid.split(separator: "@").first.map(String.init) ?? jid
            return String(userServer.split(separator: ":").first ?? Substring(userServer))
        }
        return canonical(lhs) == canonical(rhs)
    }

    private func looksLikeJIDTitle(_ title: String, jid: String) -> Bool {
        if title.isEmpty { return true }
        let local = String(jid.split(separator: "@").first ?? "")
        if title == local { return true }
        if title.allSatisfy({ $0.isNumber }) { return true }
        return false
    }

    private func isChatCurrentlyOpen(accountID: Account.ID, chatID: Chat.ID) -> Bool {
        guard let provider = selection as? any SelectionProvider else { return false }
        return provider.selectedAccountID == accountID && provider.selectedChatID == chatID
    }

    private func defaultChatTitle(jid: String, sender: String?) -> String {
        if let sender, !sender.isEmpty { return sender }
        if let prefix = jid.split(separator: "@").first { return String(prefix) }
        return jid
    }

    private func messagePreview(from incoming: IncomingMessage) -> String {
        if let body = incoming.body, !body.isEmpty { return body }
        switch incoming.kind {
        case "image": return "📷 Photo"
        case "video": return "🎬 Video"
        case "audio": return "🎤 Audio"
        case "document": return "📄 Document"
        case "sticker": return "Sticker"
        case "location": return "📍 Location"
        case "contact": return "👤 Contact"
        default: return "[message]"
        }
    }
}
