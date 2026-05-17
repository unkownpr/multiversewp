import Foundation

@MainActor
final class ChatListViewModel: ObservableObject {

    @Published private(set) var chats: [Chat] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private var loadedAccountID: Account.ID?
    private var observeTask: Task<Void, Never>?

    deinit {
        observeTask?.cancel()
    }

    func load(accountID: Account.ID, storage: AppStorage, eventBus: EventBus) async {
        let switchedAccount = loadedAccountID != accountID
        loadedAccountID = accountID
        if switchedAccount || chats.isEmpty {
            await fetch(accountID: accountID, storage: storage)
        }
        observe(accountID: accountID, storage: storage, eventBus: eventBus)
    }

    func filteredChats(query: String) -> [Chat] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return chats }
        let needle = trimmed.lowercased()
        return chats.filter { chat in
            chat.title.lowercased().contains(needle) ||
            (chat.lastMessagePreview?.lowercased().contains(needle) ?? false)
        }
    }

    private func fetch(accountID: Account.ID, storage: AppStorage) async {
        isLoading = true
        defer { isLoading = false }
        do {
            chats = try await storage.chats.chats(forAccount: accountID)
            loadError = nil
        } catch {
            chats = []
            loadError = error.localizedDescription
        }
    }

    private func observe(accountID: Account.ID, storage: AppStorage, eventBus: EventBus) {
        observeTask?.cancel()
        let stream = eventBus.stream
        observeTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                if shouldReload(for: event, accountID: accountID) {
                    await self.fetch(accountID: accountID, storage: storage)
                }
            }
        }
    }

    private func shouldReload(for event: AppEvent, accountID: Account.ID) -> Bool {
        switch event {
        case .messageReceived(let message):
            return message.accountID == accountID
        case .chatUpdated(let chat):
            return chat.accountID == accountID
        case .accountConnected(let id), .accountDisconnected(let id):
            return id == accountID
        default:
            return false
        }
    }
}
