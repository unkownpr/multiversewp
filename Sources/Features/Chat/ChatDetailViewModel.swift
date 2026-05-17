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
    private var eventTask: Task<Void, Never>?

    deinit {
        eventTask?.cancel()
    }

    func load(
        chatID: Chat.ID,
        storage: AppStorage,
        clientProvider: @escaping (Account.ID) -> WAClient
    ) async {
        self.storage = storage
        self.clientProvider = clientProvider

        loadedChatID = chatID
        do {
            let recent = try await storage.messages.messages(chatID: chatID, before: nil, limit: 50)
            messages = recent.sorted(by: { $0.timestamp < $1.timestamp })
        } catch {
            messages = []
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
            var sent = pending
            sent = Message(
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
                var failed = messages[index]
                failed = Message(
                    id: failed.id,
                    chatID: failed.chatID,
                    accountID: failed.accountID,
                    senderJID: failed.senderJID,
                    senderDisplayName: failed.senderDisplayName,
                    direction: .outgoing,
                    kind: failed.kind,
                    body: failed.body,
                    timestamp: failed.timestamp,
                    deliveryStatus: .failed
                )
                messages[index] = failed
            }
            sendError = error.localizedDescription
        }
    }

    private func loadChat(id: Chat.ID, storage: AppStorage) async -> Chat? {
        if let cached = chat, cached.id == id { return cached }
        let allAccounts = (try? await storage.accounts.allAccounts()) ?? []
        for account in allAccounts {
            let chats = (try? await storage.chats.chats(forAccount: account.id)) ?? []
            if let found = chats.first(where: { $0.id == id }) {
                chat = found
                return found
            }
        }
        return nil
    }
}
