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

    func testToolsListReturnsFullToolSurface() async throws {
        let response = try await call("""
        {"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}
        """)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }.sorted()
        XCTAssertEqual(
            names,
            [
                "check_phone",
                "create_group",
                "download_media_now",
                "get_messages",
                "get_messages_with_contact",
                "list_accounts",
                "list_chats",
                "list_group_members",
                "search_messages",
                "send_message"
            ]
        )
        // Every entry must carry a non-empty inputSchema object so AI agents
        // can call them sight-unseen — the spec calls this "self-describing".
        for tool in tools {
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any], "tool missing inputSchema: \(tool["name"] ?? "?")")
        }
        // Active write tools must not be flagged as future work.
        let descriptions = tools.compactMap { $0["description"] as? String }.joined(separator: "\n")
        XCTAssertFalse(descriptions.lowercased().contains("coming in a later milestone"))
        XCTAssertFalse(descriptions.lowercased().contains("coming in later milestone"))
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

    // MARK: - download_media_now

    func testDownloadMediaNowReturnsPathWhenMediaRowHasLocalCopy() async throws {
        // Seed a media row backed by a temp file the tool can resolve to a
        // concrete on-disk path.
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvwp-media-\(UUID().uuidString).jpg")
        try Data("bytes".utf8).write(to: tempFile)

        let alice = try await storage.accounts.allAccounts().first(where: { $0.displayName == "Alice" })
        let item = MediaItem(
            id: "m-with-media",
            accountID: try XCTUnwrap(alice?.id),
            mimeType: "image/jpeg",
            byteSize: 5,
            localPath: tempFile.path,
            downloadStatus: .completed
        )
        try await storage.media.upsert(item)

        let response = try await call("""
        {"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"download_media_now","arguments":{"message_id":"m-with-media"}}}
        """)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["media_path"] as? String, tempFile.path)
        XCTAssertEqual(decoded?["download_status"] as? String, "completed")
    }

    func testDownloadMediaNowRequiresAccountIDWhenBytesAbsent() async throws {
        // Without a cached row and without account_id, the server cannot pick
        // which helper to dispatch through. Surface that as the standard
        // missing-parameter error rather than silently returning null.
        let response = try await call("""
        {"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"download_media_now","arguments":{"message_id":"missing"}}}
        """)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    // MARK: - get_messages_with_contact

    func testGetMessagesWithContactSpansDirectAndGroupChats() async throws {
        // Seed two extra rows so the contact appears as the sender in a group
        // chat AND as the chat counterparty in a direct chat. The tool must
        // return both.
        let accounts = try await storage.accounts.allAccounts()
        let alice = try XCTUnwrap(accounts.first(where: { $0.displayName == "Alice" }))
        let contactJID = "555@s.whatsapp.net"

        let directChat = Chat(
            id: contactJID,
            accountID: alice.id,
            jid: contactJID,
            title: "Carol",
            lastMessagePreview: "ping",
            lastMessageTimestamp: Date(timeIntervalSinceReferenceDate: 10_000)
        )
        try await storage.chats.upsert(directChat)
        let directMessage = Message(
            id: "direct-1",
            chatID: contactJID,
            accountID: alice.id,
            senderJID: contactJID,
            senderDisplayName: "Carol",
            direction: .incoming,
            kind: .text,
            body: "direct hi",
            timestamp: Date(timeIntervalSinceReferenceDate: 10_001),
            deliveryStatus: .delivered
        )
        try await storage.messages.upsert(directMessage)

        let groupChat = Chat(
            id: "g1@g.us",
            accountID: alice.id,
            jid: "g1@g.us",
            title: "Group",
            isGroup: true,
            lastMessagePreview: "carol said",
            lastMessageTimestamp: Date(timeIntervalSinceReferenceDate: 11_000)
        )
        try await storage.chats.upsert(groupChat)
        let groupMessage = Message(
            id: "group-1",
            chatID: "g1@g.us",
            accountID: alice.id,
            senderJID: contactJID,
            senderDisplayName: "Carol",
            direction: .incoming,
            kind: .text,
            body: "group hi",
            timestamp: Date(timeIntervalSinceReferenceDate: 11_001),
            deliveryStatus: .delivered
        )
        try await storage.messages.upsert(groupMessage)

        let server = MCPServer(storage: readOnlyStorage)
        let payload = try await server.runGetMessagesWithContact(args: [
            "account_id": .string(alice.id.uuidString),
            "contact_jid": .string(contactJID)
        ])
        guard case .array(let entries) = payload else {
            return XCTFail("expected array payload")
        }
        let ids: Set<String> = Set(entries.compactMap { value -> String? in
            guard case .object(let dict) = value, case .string(let id)? = dict["id"] else { return nil }
            return id
        })
        XCTAssertTrue(ids.contains("direct-1"))
        XCTAssertTrue(ids.contains("group-1"))
    }

    func testGetMessagesWithContactRequiresAccountID() async throws {
        let server = MCPServer(storage: readOnlyStorage)
        do {
            _ = try await server.runGetMessagesWithContact(args: ["contact_jid": .string("x@s.whatsapp.net")])
            XCTFail("expected MCPError for missing account_id")
        } catch let error as MCPError {
            XCTAssertEqual(error.code, -32602)
        }
    }

    // MARK: - send_message dispatch

    func testSendMessageRoutesThroughWAClientProvider() async throws {
        let accounts = try await storage.accounts.allAccounts()
        let alice = try XCTUnwrap(accounts.first(where: { $0.displayName == "Alice" }))
        let mock = MockWAClient(accountID: alice.id)
        mock.sendMessageReturn = "wamid.123"

        let server = MCPServer(storage: readOnlyStorage, clientProvider: { @Sendable accountID in
            XCTAssertEqual(accountID, alice.id)
            return mock
        })
        let payload = try await server.runSendMessage(args: [
            "account_id": .string(alice.id.uuidString),
            "chat_jid": .string("111@s.whatsapp.net"),
            "text": .string("hello from MCP")
        ])
        guard case .object(let dict) = payload, case .string(let id)? = dict["message_id"] else {
            return XCTFail("expected message_id in response")
        }
        XCTAssertEqual(id, "wamid.123")
        XCTAssertEqual(mock.sentMessages.count, 1)
        XCTAssertEqual(mock.sentMessages.first?.chatJID, "111@s.whatsapp.net")
        XCTAssertEqual(mock.sentMessages.first?.text, "hello from MCP")
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

