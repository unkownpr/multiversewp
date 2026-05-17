import XCTest
@testable import MultiverseWP

@MainActor
final class ChatDetailViewModelTests: XCTestCase {

    func testSendTextOptimisticallyAppendsAndPersists() async throws {
        let storage = AppStorage.makeInMemory()
        try storage.migrateIfNeeded()
        let account = Account(displayName: "A")
        try await storage.accounts.upsert(account)
        let chat = Chat(id: "c1", accountID: account.id, jid: "111@s.whatsapp.net", title: "Alice")
        try await storage.chats.upsert(chat)

        let client = MockWAClient(accountID: account.id)
        client.sendMessageReturn = "remote-123"

        let vm = ChatDetailViewModel()
        await vm.load(chatID: chat.id, storage: storage, clientProvider: { _ in client }, eventBus: EventBus())

        await vm.sendText("Hello!")

        XCTAssertEqual(client.sentMessages.count, 1)
        XCTAssertEqual(client.sentMessages.first?.text, "Hello!")
        XCTAssertEqual(vm.messages.last?.id, "remote-123")
        XCTAssertEqual(vm.messages.last?.deliveryStatus, .sent)
        let stored = try await storage.messages.messages(chatID: chat.id, before: nil, limit: 10)
        XCTAssertTrue(stored.contains(where: { $0.id == "remote-123" }))
    }

    func testEmptyTextDoesNotSend() async throws {
        let storage = AppStorage.makeInMemory()
        try storage.migrateIfNeeded()
        let account = Account(displayName: "A")
        try await storage.accounts.upsert(account)
        let chat = Chat(id: "c2", accountID: account.id, jid: "j", title: "Z")
        try await storage.chats.upsert(chat)

        let client = MockWAClient(accountID: account.id)
        let vm = ChatDetailViewModel()
        await vm.load(chatID: chat.id, storage: storage, clientProvider: { _ in client }, eventBus: EventBus())

        await vm.sendText("   ")
        XCTAssertEqual(client.sentMessages.count, 0)
    }
}
