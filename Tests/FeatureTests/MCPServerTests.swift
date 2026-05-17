import Foundation
import GRDB
import XCTest
@testable import MultiverseWP

@MainActor
final class MCPServerTests: XCTestCase {

    private var storage: AppStorage!
    private var dbPath: String!
    private var readOnlyStorage: MCPReadOnlyStorage!

    override func setUp() async throws {
        try await super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiversewp-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        dbPath = dbURL.path
        let writerPool = try DatabasePool(path: dbPath)
        storage = AppStorage(dbPool: writerPool)
        try storage.migrateIfNeeded()

        // Seed two accounts and a small dataset so every tool has something
        // meaningful to return.
        let alice = Account(displayName: "Alice", phoneNumber: "+10001", connectionState: .connected, lastConnectedAt: Date(timeIntervalSinceReferenceDate: 1000))
        let bob = Account(displayName: "Bob", phoneNumber: "+20002", connectionState: .disconnected)
        try await storage.accounts.upsert(alice)
        try await storage.accounts.upsert(bob)

        let chat = Chat(
            id: "chat-1",
            accountID: alice.id,
            jid: "111@s.whatsapp.net",
            title: "Family",
            lastMessagePreview: "see you soon",
            lastMessageTimestamp: Date(timeIntervalSinceReferenceDate: 2_000),
            unreadCount: 2
        )
        try await storage.chats.upsert(chat)

        for index in 0..<3 {
            let msg = Message(
                id: "m-\(index)",
                chatID: chat.id,
                accountID: alice.id,
                senderJID: "111@s.whatsapp.net",
                senderDisplayName: "Sender",
                direction: .incoming,
                kind: .text,
                body: index == 1 ? "Dentist appointment tomorrow" : "hello \(index)",
                timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
                deliveryStatus: .delivered
            )
            try await storage.messages.upsert(msg)
        }

        // Read-only pool talking to the same file the writer just populated.
        var config = Configuration()
        config.readonly = true
        let readerPool = try DatabasePool(path: dbPath, configuration: config)
        readOnlyStorage = MCPReadOnlyStorage(dbPool: readerPool)
    }

    // MARK: - Initialize handshake

    func testInitializeReturnsServerInfoAndCapabilities() async throws {
        let response = try await call("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
        """)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "multiversewp")
        XCTAssertNotNil(result["capabilities"])
    }

    func testToolsListReturnsFourReadOnlyTools() async throws {
        let response = try await call("""
        {"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}
        """)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }.sorted()
        XCTAssertEqual(names, ["get_messages", "list_accounts", "list_chats", "search_messages"])
    }

    func testUnknownMethodReturnsMethodNotFound() async throws {
        let response = try await call("""
        {"jsonrpc":"2.0","id":99,"method":"who_am_i"}
        """)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    // MARK: - Tool parameter validation

    func testListChatsAccountIDMustBeUUID() async throws {
        let server = MCPServer(storage: readOnlyStorage)
        do {
            _ = try await server.runListChats(args: ["account_id": .string("not-a-uuid")])
            XCTFail("expected MCPError for invalid uuid")
        } catch let error as MCPError {
            XCTAssertEqual(error.code, -32602)
        }
    }

    func testGetMessagesRequiresChatID() async throws {
        let server = MCPServer(storage: readOnlyStorage)
        do {
            _ = try await server.runGetMessages(args: [:])
            XCTFail("expected MCPError for missing chat_id")
        } catch let error as MCPError {
            XCTAssertEqual(error.code, -32602)
        }
    }

    func testSearchMessagesRequiresQuery() async throws {
        let server = MCPServer(storage: readOnlyStorage)
        do {
            _ = try await server.runSearchMessages(args: [:])
            XCTFail("expected MCPError for missing query")
        } catch let error as MCPError {
            XCTAssertEqual(error.code, -32602)
        }
    }

    func testLimitClampsToBounds() throws {
        let server = MCPServer(storage: readOnlyStorage)
        XCTAssertEqual(try server.clampedInt(.int(500), field: "limit", default: 50, min: 1, max: 200), 200)
        XCTAssertEqual(try server.clampedInt(.int(0), field: "limit", default: 50, min: 1, max: 200), 1)
        XCTAssertEqual(try server.clampedInt(nil, field: "limit", default: 50, min: 1, max: 200), 50)
    }

    // MARK: - End-to-end tools/call

    func testToolsCallListAccountsReturnsTwo() async throws {
        let response = try await call("""
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_accounts","arguments":{}}}
        """)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 2)
    }

    func testToolsCallSearchMessagesHitsFTS() async throws {
        let response = try await call("""
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_messages","arguments":{"query":"dentist"}}}
        """)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?["body"] as? String, "Dentist appointment tomorrow")
    }

    // MARK: - Helpers

    /// Sends a single JSON-RPC frame to a freshly-built server via in-memory
    /// pipes and decodes the first response line.
    private func call(_ line: String) async throws -> [String: Any] {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let server = MCPServer(
            storage: readOnlyStorage,
            stdin: stdinPipe.fileHandleForReading,
            stdout: stdoutPipe.fileHandleForWriting,
            stderr: stderrPipe.fileHandleForWriting
        )

        try stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        try stdinPipe.fileHandleForWriting.close()

        await server.run()
        try? stdoutPipe.fileHandleForWriting.close()

        let data = stdoutPipe.fileHandleForReading.availableData
        guard let firstLine = String(data: data, encoding: .utf8)?
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)
        else {
            XCTFail("No stdout response")
            return [:]
        }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
        )
    }
}

