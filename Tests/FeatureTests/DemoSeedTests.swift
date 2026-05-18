import Foundation
import GRDB
import XCTest
@testable import MultiverseWP

@MainActor
final class DemoSeedTests: XCTestCase {

    private var storage: AppStorage!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiversewp-demo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        dbPath = dbURL.path
        let pool = try DatabasePool(path: dbPath)
        storage = AppStorage(dbPool: pool)
        try storage.migrateIfNeeded()
    }

    // MARK: - DemoSeed.seed

    func testSeedInsertsOneDemoAccountWithThreeChats() async throws {
        _ = try await DemoSeed.seed(into: storage)

        let accounts = try await storage.accounts.allAccounts()
        XCTAssertEqual(accounts.count, 1)
        let account = try XCTUnwrap(accounts.first)
        XCTAssertTrue(account.isDemo)
        XCTAssertEqual(account.displayName, "MultiverseWP Demo")
        XCTAssertEqual(account.connectionState, .connected)

        let chats = try await storage.chats.chats(forAccount: account.id)
        XCTAssertEqual(chats.count, 3)
        let titles = Set(chats.map(\.title))
        XCTAssertTrue(titles.contains("👋 Welcome to MultiverseWP"))
        XCTAssertTrue(titles.contains("🤖 MCP & AI Assistants"))
        XCTAssertTrue(titles.contains("📢 News & Updates"))
    }

    func testSeededChatsHaveSystemIncomingMessages() async throws {
        let account = try await DemoSeed.seed(into: storage)
        let chats = try await storage.chats.chats(forAccount: account.id)
        for chat in chats {
            let messages = try await storage.messages.messages(chatID: chat.id, before: nil, limit: 50)
            XCTAssertGreaterThanOrEqual(messages.count, 3, "chat \(chat.title) should have at least 3 messages")
            for message in messages {
                XCTAssertEqual(message.direction, .incoming, "demo messages must be incoming")
                XCTAssertEqual(message.kind, .system, "demo messages must be system kind")
                XCTAssertEqual(message.senderJID, "demo@multiversewp")
                XCTAssertEqual(message.senderDisplayName, "MultiverseWP")
                XCTAssertNotNil(message.body)
            }
        }
    }

    func testDemoTimestampsAreRecentRelativeToNow() async throws {
        let now = Date()
        let account = try await DemoSeed.seed(into: storage, now: now)
        let chats = try await storage.chats.chats(forAccount: account.id)
        let oldestAllowed = now.addingTimeInterval(-7 * 24 * 3_600)
        for chat in chats {
            let messages = try await storage.messages.messages(chatID: chat.id, before: nil, limit: 50)
            for message in messages {
                XCTAssertGreaterThan(message.timestamp, oldestAllowed)
                XCTAssertLessThanOrEqual(message.timestamp, now)
            }
        }
    }

    // MARK: - DemoSeed.hasRealAccounts

    func testHasRealAccountsTreatsDemoAsAbsent() throws {
        let demo = Account(displayName: "MultiverseWP Demo", isDemo: true)
        XCTAssertFalse(DemoSeed.hasRealAccounts([demo]))
        XCTAssertFalse(DemoSeed.hasRealAccounts([]))
    }

    func testHasRealAccountsTrueWhenRealAccountPresent() throws {
        let demo = Account(displayName: "MultiverseWP Demo", isDemo: true)
        let real = Account(displayName: "Personal")
        XCTAssertTrue(DemoSeed.hasRealAccounts([demo, real]))
        XCTAssertTrue(DemoSeed.hasRealAccounts([real]))
    }

    // MARK: - Persistence round-trip of isDemo

    func testIsDemoColumnRoundTrips() async throws {
        var account = Account(displayName: "Demo", isDemo: true)
        try await storage.accounts.upsert(account)
        var fetched = try await storage.accounts.allAccounts().first
        XCTAssertEqual(fetched?.isDemo, true)

        // Default false on existing rows.
        account = Account(displayName: "Real")
        try await storage.accounts.upsert(account)
        let allAccounts = try await storage.accounts.allAccounts()
        let real = allAccounts.first(where: { $0.displayName == "Real" })
        fetched = allAccounts.first(where: { $0.displayName == "Demo" })
        XCTAssertEqual(real?.isDemo, false)
        XCTAssertEqual(fetched?.isDemo, true)
    }

    // MARK: - MCP filter

    func testMCPReadOnlyStorageHidesDemoAccountAndChats() async throws {
        _ = try await DemoSeed.seed(into: storage)
        // Also seed a *real* account so the assertions are meaningful.
        let realAccount = Account(displayName: "Personal", connectionState: .connected)
        try await storage.accounts.upsert(realAccount)
        let realChat = Chat(
            id: "real-chat",
            accountID: realAccount.id,
            jid: "555@s.whatsapp.net",
            title: "Real Friend",
            lastMessagePreview: "hi there",
            lastMessageTimestamp: Date()
        )
        try await storage.chats.upsert(realChat)
        let realMessage = Message(
            id: "real-msg-1",
            chatID: realChat.id,
            accountID: realAccount.id,
            senderJID: "555@s.whatsapp.net",
            direction: .incoming,
            kind: .text,
            body: "Hello from a real chat",
            timestamp: Date(),
            deliveryStatus: .delivered
        )
        try await storage.messages.upsert(realMessage)

        // Open a *separate* read-only pool against the same file the seeder
        // wrote to — same shape MCPServer.makeProductionServer uses.
        var config = Configuration()
        config.readonly = true
        let readerPool = try DatabasePool(path: dbPath, configuration: config)
        let readOnly = MCPReadOnlyStorage(dbPool: readerPool)

        let accounts = try await readOnly.allAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.displayName, "Personal")

        let chats = try await readOnly.chats(accountID: nil, query: nil, limit: 50)
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats.first?.id, "real-chat")

        // Even if a caller knows the demo chat ID, get_messages should return
        // nothing because the join filters demo accounts out.
        let demoMessages = try await readOnly.messages(chatID: "demo-welcome", before: nil, limit: 50)
        XCTAssertTrue(demoMessages.isEmpty)

        let realMessages = try await readOnly.messages(chatID: "real-chat", before: nil, limit: 50)
        XCTAssertEqual(realMessages.count, 1)

        // FTS search should not surface demo bodies.
        let demoHits = try await readOnly.search(query: "Welcome", accountID: nil, chatID: nil, limit: 25)
        XCTAssertTrue(demoHits.isEmpty, "demo messages must not appear in MCP search results")

        let realHits = try await readOnly.search(query: "real", accountID: nil, chatID: nil, limit: 25)
        XCTAssertEqual(realHits.count, 1)
    }

    // MARK: - Removing the demo and re-seed protection

    func testDeletingDemoAccountCascadesChatsAndMessages() async throws {
        let account = try await DemoSeed.seed(into: storage)
        try await storage.accounts.delete(id: account.id)

        let accounts = try await storage.accounts.allAccounts()
        XCTAssertTrue(accounts.isEmpty)

        let messages = try await storage.messages.messages(chatID: "demo-welcome", before: nil, limit: 10)
        XCTAssertTrue(messages.isEmpty, "cascade delete must remove demo messages")
    }
}
