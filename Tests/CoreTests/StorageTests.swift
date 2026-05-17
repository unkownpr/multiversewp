import GRDB
import XCTest
@testable import MultiverseWP

final class StorageTests: XCTestCase {

    private var storage: AppStorage!

    override func setUp() async throws {
        try await super.setUp()
        storage = AppStorage.makeInMemory()
        try storage.migrateIfNeeded()
    }

    func testMigrationCreatesCoreTables() async throws {
        let account = Account(displayName: "Personal")
        try await storage.accounts.upsert(account)
        let fetched = try await storage.accounts.allAccounts()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.displayName, "Personal")
    }

    func testChatUpsertAndOrdering() async throws {
        let account = Account(displayName: "Work")
        try await storage.accounts.upsert(account)

        let older = Chat(
            id: "chat-1",
            accountID: account.id,
            jid: "1111@s.whatsapp.net",
            title: "Alice",
            lastMessageTimestamp: Date(timeIntervalSinceNow: -3600)
        )
        let newer = Chat(
            id: "chat-2",
            accountID: account.id,
            jid: "2222@s.whatsapp.net",
            title: "Bob",
            lastMessageTimestamp: Date()
        )
        try await storage.chats.upsert(older)
        try await storage.chats.upsert(newer)

        let chats = try await storage.chats.chats(forAccount: account.id)
        XCTAssertEqual(chats.first?.id, "chat-2")
    }

    func testUnreadCounterIsolation() async throws {
        let account = Account(displayName: "Work")
        try await storage.accounts.upsert(account)
        let chat = Chat(id: "chat-3", accountID: account.id, jid: "x", title: "X")
        try await storage.chats.upsert(chat)

        try await storage.chats.incrementUnread(for: chat.id, by: 3)
        try await storage.chats.incrementUnread(for: chat.id, by: 2)

        let stored = try await storage.chats.chats(forAccount: account.id).first
        XCTAssertEqual(stored?.unreadCount, 5)

        try await storage.chats.resetUnread(for: chat.id)
        let reset = try await storage.chats.chats(forAccount: account.id).first
        XCTAssertEqual(reset?.unreadCount, 0)
    }

    func testMessageInsertionAndOrdering() async throws {
        let account = Account(displayName: "Test")
        try await storage.accounts.upsert(account)
        let chat = Chat(id: "chat-A", accountID: account.id, jid: "j", title: "T")
        try await storage.chats.upsert(chat)

        for index in 0..<5 {
            let message = Message(
                id: "m-\(index)",
                chatID: chat.id,
                accountID: account.id,
                senderJID: "x",
                direction: .incoming,
                kind: .text,
                body: "msg \(index)",
                timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
                deliveryStatus: .delivered
            )
            try await storage.messages.upsert(message)
        }

        let recent = try await storage.messages.messages(chatID: chat.id, before: nil, limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.first?.id, "m-4")
        XCTAssertEqual(recent.last?.id, "m-2")
    }

    func testFullTextSearchFindsBody() async throws {
        let account = Account(displayName: "Test")
        try await storage.accounts.upsert(account)
        let chat = Chat(id: "chat-S", accountID: account.id, jid: "j", title: "Search")
        try await storage.chats.upsert(chat)

        let payloads = [
            "Lunch with Ada tomorrow",
            "Send the invoice today",
            "Ada will join the call"
        ]
        for (offset, body) in payloads.enumerated() {
            let message = Message(
                id: "s-\(offset)",
                chatID: chat.id,
                accountID: account.id,
                senderJID: "j",
                direction: .incoming,
                kind: .text,
                body: body,
                timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(offset))
            )
            try await storage.messages.upsert(message)
        }

        let hits = try await storage.messages.search(text: "Ada", accountID: account.id, chatID: chat.id, limit: 10)
        XCTAssertEqual(hits.count, 2)
        let bodies = Set(hits.compactMap(\.body))
        XCTAssertTrue(bodies.contains("Lunch with Ada tomorrow"))
        XCTAssertTrue(bodies.contains("Ada will join the call"))
    }

    func testContactSearchByPushName() async throws {
        let account = Account(displayName: "Test")
        try await storage.accounts.upsert(account)
        let contacts = [
            Contact(id: "c-1", accountID: account.id, jid: "1@x", pushName: "Aylin"),
            Contact(id: "c-2", accountID: account.id, jid: "2@x", pushName: "Burak"),
            Contact(id: "c-3", accountID: account.id, jid: "3@x", pushName: "Aysel")
        ]
        for contact in contacts { try await storage.contacts.upsert(contact) }

        let matches = try await storage.contacts.contacts(forAccount: account.id, query: "Ay")
        XCTAssertEqual(matches.count, 2)
    }
}
