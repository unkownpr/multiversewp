import Foundation
import UniformTypeIdentifiers

/// User-selected attachment awaiting send. Wraps the picked file URL together
/// with the derived MIME type and message kind so the composer chip and the
/// outgoing pipeline share one source of truth.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let mimeType: String
    let kind: Message.Kind
    let byteSize: Int64?

    init(url: URL) {
        self.url = url
        let utType = UTType(filenameExtension: url.pathExtension.lowercased())
        let derivedMime = utType?.preferredMIMEType ?? "application/octet-stream"
        self.mimeType = derivedMime
        self.kind = Self.kind(for: derivedMime)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.byteSize = (attributes?[.size] as? NSNumber)?.int64Value
    }

    static func kind(for mimeType: String) -> Message.Kind {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") { return .image }
        if lower.hasPrefix("video/") { return .video }
        if lower.hasPrefix("audio/") { return .audio }
        return .document
    }

    var displayName: String { url.lastPathComponent }

    var symbolName: String {
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc"
        default: return "paperclip"
        }
    }
}

@MainActor
final class ChatDetailViewModel: ObservableObject {

    @Published private(set) var messages: [Message] = []
    @Published private(set) var media: [Message.ID: MediaItem] = [:]
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

    /// Trigger an on-demand decryption + download for a media-bearing message
    /// whose bytes are not yet on disk (size cap hit, or auto-download
    /// previously failed). The helper writes the file under its session
    /// `media/` directory; the resulting MediaItem update flows back through
    /// the regular delivery / event-bus pipeline.
    func downloadMedia(for messageID: Message.ID) async {
        guard let storage,
              let clientProvider,
              let message = messages.first(where: { $0.id == messageID })
        else { return }
        let client = clientProvider(message.accountID)
        do {
            let url = try await client.downloadMedia(messageID: messageID)
            // Heal the media row immediately so the UI re-renders without
            // waiting for the asynchronous delivery event.
            let existing = try? await storage.media.media(id: messageID)
            let item = MediaItem(
                id: messageID,
                accountID: message.accountID,
                mimeType: existing?.mimeType ?? "application/octet-stream",
                byteSize: existing?.byteSize ?? 0,
                localPath: url.path,
                remoteURL: existing?.remoteURL,
                caption: existing?.caption,
                downloadStatus: .completed
            )
            try await storage.media.upsert(item)
            media[messageID] = item
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// Bump the chat's unread counter so the sidebar re-flags it; lets the
    /// user revisit a chat later. Wired to the chat-header ellipsis menu.
    func markUnreadAgain() async {
        guard let chatID = loadedChatID, let storage else { return }
        try? await storage.chats.incrementUnread(for: chatID, by: 1)
        if let refreshed = try? await storage.chats.chat(id: chatID) {
            chat = refreshed
            eventBusRef?.publish(.chatUpdated(refreshed))
        }
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

    /// Sends a media attachment (image / video / audio / document) optionally
    /// captioned with `text`. The caller is responsible for vetting the file —
    /// the helper will read, upload, and emit the corresponding *waE2E.Message
    /// type. The wire-protocol `kind` is inferred from the attachment kind.
    func sendAttachment(text: String, attachment: PendingAttachment) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chatID = loadedChatID,
              let storage,
              let clientProvider,
              let chat = await loadChat(id: chatID, storage: storage)
        else { return }

        let pendingID = "local-\(UUID().uuidString)"
        let kind = attachment.kind
        let pending = Message(
            id: pendingID,
            chatID: chatID,
            accountID: chat.accountID,
            senderJID: chat.jid,
            senderDisplayName: nil,
            direction: .outgoing,
            kind: kind,
            body: trimmed.isEmpty ? nil : trimmed,
            mediaID: pendingID,
            timestamp: Date(),
            deliveryStatus: .pending
        )
        messages.append(pending)
        let optimisticMedia = MediaItem(
            id: pendingID,
            accountID: chat.accountID,
            mimeType: attachment.mimeType,
            byteSize: attachment.byteSize ?? 0,
            localPath: attachment.url.path,
            caption: pending.body,
            downloadStatus: .completed
        )
        media[pendingID] = optimisticMedia
        isSending = true
        defer { isSending = false }

        do {
            try await storage.media.upsert(optimisticMedia)
            try await storage.messages.upsert(pending)
            let client = clientProvider(chat.accountID)
            let remoteID = try await client.sendMessage(
                SendMessageRequest(
                    chatJID: chat.jid,
                    text: nil,
                    mediaPath: attachment.url.path,
                    mediaMimeType: attachment.mimeType,
                    caption: trimmed.isEmpty ? nil : trimmed
                )
            )
            // Promote optimistic row to the server-assigned ID so subsequent
            // delivery / receipt events line up. We rewrite both the message
            // and the associated MediaItem so the bubble keeps the inline
            // thumbnail through the swap.
            let sent = Message(
                id: remoteID,
                chatID: pending.chatID,
                accountID: pending.accountID,
                senderJID: pending.senderJID,
                senderDisplayName: pending.senderDisplayName,
                direction: .outgoing,
                kind: pending.kind,
                body: pending.body,
                mediaID: remoteID,
                timestamp: pending.timestamp,
                deliveryStatus: .sent
            )
            let sentMedia = MediaItem(
                id: remoteID,
                accountID: optimisticMedia.accountID,
                mimeType: optimisticMedia.mimeType,
                byteSize: optimisticMedia.byteSize,
                localPath: optimisticMedia.localPath,
                caption: optimisticMedia.caption,
                downloadStatus: .completed
            )
            if let index = messages.firstIndex(where: { $0.id == pendingID }) {
                messages[index] = sent
            }
            media.removeValue(forKey: pendingID)
            media[remoteID] = sentMedia
            try await storage.media.upsert(sentMedia)
            try await storage.messages.upsert(sent)
            sendError = nil
        } catch {
            if let index = messages.firstIndex(where: { $0.id == pendingID }) {
                let failed = Message(
                    id: messages[index].id,
                    chatID: messages[index].chatID,
                    accountID: messages[index].accountID,
                    senderJID: messages[index].senderJID,
                    senderDisplayName: messages[index].senderDisplayName,
                    direction: .outgoing,
                    kind: messages[index].kind,
                    body: messages[index].body,
                    mediaID: messages[index].mediaID,
                    timestamp: messages[index].timestamp,
                    deliveryStatus: .failed
                )
                messages[index] = failed
            }
            sendError = error.localizedDescription
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
            // Pull every referenced MediaItem in one pass. This is O(message
            // count) but the chat detail only renders ~50 rows at a time so the
            // overhead is negligible compared to the network / disk work.
            var loaded: [Message.ID: MediaItem] = [:]
            for message in messages {
                guard let mediaID = message.mediaID else { continue }
                if let item = try? await storage.media.media(id: mediaID) {
                    loaded[message.id] = item
                }
            }
            media = loaded
        } catch {
            messages = []
            media = [:]
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
