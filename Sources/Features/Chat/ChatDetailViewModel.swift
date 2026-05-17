import Foundation

@MainActor
final class ChatDetailViewModel: ObservableObject {

    @Published private(set) var messages: [Message] = []
    @Published private(set) var chat: Chat?
    @Published private(set) var sendError: String?
    @Published private(set) var isSending = false

    private var loadedChatID: Chat.ID?
    private var storage: AppStorage?
    private var clientProvider: ((Account.ID) -> WAClient)?
    private var eventBusRef: EventBus?
    private var observeTask: Task<Void, Never>?

    deinit {
        observeTask?.cancel()
    }

    func load(
        chatID: Chat.ID,
        storage: AppStorage,
        clientProvider: @escaping (Account.ID) -> WAClient,
        eventBus: EventBus? = nil
    ) async {
        self.storage = storage
        self.clientProvider = clientProvider
        self.eventBusRef = eventBus

        loadedChatID = chatID
        await reload(chatID: chatID, storage: storage)
        if let eventBus {
            observe(chatID: chatID, storage: storage, eventBus: eventBus)
        }
    }

    func sendText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let chatID = loadedChatID,
              let storage,
              let clientProvider,
              let chat = await loadChat(id: chatID, storage: storage)
        else { return }

        let pending = Message(
            id: "local-\(UUID().uuidString)",
            chatID: chatID,
            accountID: chat.accountID,
            senderJID: chat.jid,
            senderDisplayName: nil,
            direction: .outgoing,
            kind: .text,
            body: trimmed,
            timestamp: Date(),
            deliveryStatus: .pending
        )
        messages.append(pending)
        isSending = true
        defer { isSending = false }

        do {
            try await storage.messages.upsert(pending)
            let client = clientProvider(chat.accountID)
            let remoteID = try await client.sendMessage(
                SendMessageRequest(chatJID: chat.jid, text: trimmed)
            )
            let sent = Message(
                id: remoteID,
                chatID: pending.chatID,
                accountID: pending.accountID,
                senderJID: pending.senderJID,
                senderDisplayName: pending.senderDisplayName,
                direction: .outgoing,
                kind: .text,
                body: pending.body,
                timestamp: pending.timestamp,
                deliveryStatus: .sent
            )
            if let index = messages.firstIndex(where: { $0.id == pending.id }) {
                messages[index] = sent
            }
            try await storage.messages.upsert(sent)
            sendError = nil
        } catch {
            if let index = messages.firstIndex(where: { $0.id == pending.id }) {
                let failed = Message(
                    id: messages[index].id,
                    chatID: messages[index].chatID,
                    accountID: messages[index].accountID,
                    senderJID: messages[index].senderJID,
                    senderDisplayName: messages[index].senderDisplayName,
                    direction: .outgoing,
                    kind: messages[index].kind,
                    body: messages[index].body,
                    timestamp: messages[index].timestamp,
                    deliveryStatus: .failed
                )
                messages[index] = failed
            }
            sendError = error.localizedDescription
        }
    }

    private func reload(chatID: Chat.ID, storage: AppStorage) async {
        do {
            chat = try await storage.chats.chat(id: chatID)
            let recent = try await storage.messages.messages(chatID: chatID, before: nil, limit: 50)
            messages = recent.sorted(by: { $0.timestamp < $1.timestamp })
        } catch {
            messages = []
        }
    }

    private func observe(chatID: Chat.ID, storage: AppStorage, eventBus: EventBus) {
        observeTask?.cancel()
        let stream = eventBus.stream
        observeTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .messageReceived(let message) where message.chatID == chatID:
                    await self.reload(chatID: chatID, storage: storage)
                case .messageDeliveryUpdated(let id, let status):
                    if let index = self.messages.firstIndex(where: { $0.id == id }) {
                        let m = self.messages[index]
                        self.messages[index] = Message(
                            id: m.id, chatID: m.chatID, accountID: m.accountID,
                            senderJID: m.senderJID, senderDisplayName: m.senderDisplayName,
                            direction: m.direction, kind: m.kind, body: m.body,
                            timestamp: m.timestamp, deliveryStatus: status,
                            isStarred: m.isStarred, isDeleted: m.isDeleted
                        )
                    }
                default:
                    break
                }
            }
        }
    }

    private func loadChat(id: Chat.ID, storage: AppStorage) async -> Chat? {
        if let cached = chat, cached.id == id { return cached }
        let found = try? await storage.chats.chat(id: id)
        chat = found
        return found
    }
}
