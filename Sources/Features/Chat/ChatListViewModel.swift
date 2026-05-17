import Foundation

@MainActor
final class ChatListViewModel: ObservableObject {

    @Published private(set) var chats: [Chat] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private var loadedAccountID: Account.ID?

    func load(accountID: Account.ID, storage: AppStorage) async {
        if loadedAccountID == accountID, !chats.isEmpty { return }
        loadedAccountID = accountID
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

    func filteredChats(query: String) -> [Chat] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return chats }
        let needle = trimmed.lowercased()
        return chats.filter { chat in
            chat.title.lowercased().contains(needle) ||
            (chat.lastMessagePreview?.lowercased().contains(needle) ?? false)
        }
    }
}
