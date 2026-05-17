import XCTest
@testable import MultiverseWP

@MainActor
final class ChatListViewModelTests: XCTestCase {

    func testLoadFetchesChatsForAccount() async throws {
        let storage = AppStorage.makeInMemory()
        try storage.migrateIfNeeded()
        let account = Account(displayName: "A")
        try await storage.accounts.upsert(account)
        try await storage.chats.upsert(
            Chat(id: "c1", accountID: account.id, jid: "a@x", title: "First")
        )
        try await storage.chats.upsert(
            Chat(id: "c2", accountID: account.id, jid: "b@x", title: "Second")
        )

        let vm = ChatListViewModel()
        await vm.load(accountID: account.id, storage: storage, eventBus: EventBus())
        XCTAssertEqual(vm.chats.count, 2)
    }

    func testFilteredChatsRespectsQuery() async throws {
        let storage = AppStorage.makeInMemory()
        try storage.migrateIfNeeded()
        let account = Account(displayName: "A")
        try await storage.accounts.upsert(account)
        try await storage.chats.upsert(Chat(id: "c1", accountID: account.id, jid: "a", title: "Alice"))
        try await storage.chats.upsert(Chat(id: "c2", accountID: account.id, jid: "b", title: "Bob"))

        let vm = ChatListViewModel()
        await vm.load(accountID: account.id, storage: storage, eventBus: EventBus())
        XCTAssertEqual(vm.filteredChats(query: "ali").count, 1)
        XCTAssertEqual(vm.filteredChats(query: "").count, 2)
    }
}
