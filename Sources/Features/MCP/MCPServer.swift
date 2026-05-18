import Foundation
import GRDB
import OSLog

// MARK: - Public entry point

/// Stdio-based Model Context Protocol server for MultiverseWP.
///
/// Read-only by design in this milestone: every tool inspects the shared SQLite
/// store via a `DatabasePool` opened with `Configuration.readonly = true`, so
/// the running app can keep writing while one or more MCP processes serve
/// queries to AI clients (Claude Desktop, Claude Code, etc.).
///
/// Wire format:
/// - JSON-RPC 2.0 framing, newline-delimited objects on stdin / stdout.
/// - Stdout is reserved for protocol frames; every log line goes to stderr.
public final class MCPServer: @unchecked Sendable {

    public struct Options: Sendable {
        public var protocolVersion: String
        public var serverName: String
        public var serverVersion: String
        public init(
            protocolVersion: String = "2025-06-18",
            serverName: String = "multiversewp",
            serverVersion: String = "0.1.0"
        ) {
            self.protocolVersion = protocolVersion
            self.serverName = serverName
            self.serverVersion = serverVersion
        }
    }

    public enum RunError: Error {
        case storageUnavailable(String)
    }

    /// Async-throwing factory the write-tool handlers use to obtain a connected
    /// `WAClient` for a given account UUID. Lazily invoked the first time a
    /// write tool fires; the MCP process owns the helper child it spawns.
    public typealias WAClientProvider = @Sendable (Account.ID) async throws -> WAClient

    private let options: Options
    private let storage: MCPReadOnlyStorage
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let clientProvider: WAClientProvider?
    private let log = Logger(subsystem: "com.semihsilistre.multiversewp", category: "MCPServer")

    public init(
        options: Options = Options(),
        storage: MCPReadOnlyStorage,
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput,
        stderr: FileHandle = .standardError,
        clientProvider: WAClientProvider? = nil
    ) {
        self.options = options
        self.storage = storage
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.clientProvider = clientProvider
    }

    /// Convenience constructor that opens the production SQLite file at
    /// `~/Library/Application Support/MultiverseWP/multiverse.sqlite` in
    /// read-only mode and prepares an on-demand `WAClient` factory backed by
    /// the same helper binary the GUI uses. Write tools dispatch through this
    /// factory; read tools only ever touch the SQLite mirror.
    public static func makeProductionServer(
        options: Options = Options()
    ) throws -> MCPServer {
        let storage = try MCPReadOnlyStorage.makeDefault()
        let factory = WAClientFactory()
        let keychain = KeychainStore(service: KeychainStore.defaultService)
        let provider = MCPWAClientPool(factory: factory, keychain: keychain)
        return MCPServer(
            options: options,
            storage: storage,
            clientProvider: { accountID in
                try await provider.client(for: accountID)
            }
        )
    }

    /// Block the current thread, processing JSON-RPC frames from stdin until
    /// stdin closes. Returns when the peer disconnects (EOF).
    public func run() async {
        logToStderr("MultiverseWP MCP server starting (protocol=\(options.protocolVersion))")
        let reader = LineReader(handle: stdin)

        while let line = reader.next() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            await handleLine(trimmed)
        }
        logToStderr("MultiverseWP MCP server stdin closed; exiting")
    }

    // MARK: - Frame handling

    func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            writeError(id: nil, code: -32700, message: "Parse error: not UTF-8")
            return
        }
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            writeError(id: nil, code: -32700, message: "Parse error: \(error.localizedDescription)")
            return
        }
        guard request.jsonrpc == "2.0" else {
            writeError(id: request.id, code: -32600, message: "Invalid Request: jsonrpc must be 2.0")
            return
        }
        do {
            try await dispatch(request: request)
        } catch let mcpError as MCPError {
            writeError(id: request.id, code: mcpError.code, message: mcpError.message)
        } catch {
            writeError(id: request.id, code: -32603, message: "Internal error: \(error.localizedDescription)")
        }
    }

    private func dispatch(request: JSONRPCRequest) async throws {
        switch request.method {
        case "initialize":
            try writeResult(id: request.id, result: initializeResult())
        case "ping":
            try writeResult(id: request.id, result: [String: JSONValue]())
        case "notifications/initialized":
            // Spec says these are notifications — no response.
            return
        case "tools/list":
            try writeResult(id: request.id, result: toolsListResult())
        case "tools/call":
            let result = try await handleToolsCall(params: request.params)
            try writeResult(id: request.id, result: result)
        default:
            throw MCPError(code: -32601, message: "Method not found: \(request.method)")
        }
    }

    // MARK: - Initialize

    private func initializeResult() -> [String: JSONValue] {
        [
            "protocolVersion": .string(options.protocolVersion),
            "capabilities": .object([
                "tools": .object([
                    "listChanged": .bool(false)
                ])
            ]),
            "serverInfo": .object([
                "name": .string(options.serverName),
                "version": .string(options.serverVersion)
            ]),
            "instructions": .string(
                "Local MultiverseWP bridge. Read tools serve the SQLite mirror; "
                + "write tools (send_message, create_group, download_media_now) dispatch "
                + "through the whatsmeow helper. Personal-use single-tenant setup — every "
                + "call is owner-initiated."
            )
        ]
    }

    // MARK: - Tools

    private func toolsListResult() -> [String: JSONValue] {
        let descriptors: [MCPToolDescriptor] = [
            .listAccounts,
            .listChats,
            .getMessages,
            .getMessagesWithContact,
            .searchMessages,
            .downloadMediaNow,
            .sendMessage,
            .listGroupMembers,
            .createGroup,
            .checkPhone
        ]
        return [
            "tools": .array(descriptors.map { $0.toolEntry })
        ]
    }

    private func handleToolsCall(params: JSONValue?) async throws -> [String: JSONValue] {
        guard case .object(let dict)? = params else {
            throw MCPError(code: -32602, message: "Invalid params: expected object")
        }
        guard case .string(let toolName)? = dict["name"] else {
            throw MCPError(code: -32602, message: "Invalid params: missing tool 'name'")
        }
        let arguments: JSONValue = dict["arguments"] ?? .object([:])
        guard case .object(let argsDict) = arguments else {
            throw MCPError(code: -32602, message: "Invalid params: 'arguments' must be an object")
        }

        let payload: JSONValue
        switch toolName {
        case MCPToolDescriptor.listAccounts.name:
            payload = try await runListAccounts(args: argsDict)
        case MCPToolDescriptor.listChats.name:
            payload = try await runListChats(args: argsDict)
        case MCPToolDescriptor.getMessages.name:
            payload = try await runGetMessages(args: argsDict)
        case MCPToolDescriptor.getMessagesWithContact.name:
            payload = try await runGetMessagesWithContact(args: argsDict)
        case MCPToolDescriptor.searchMessages.name:
            payload = try await runSearchMessages(args: argsDict)
        case MCPToolDescriptor.downloadMediaNow.name:
            payload = try await runDownloadMediaNow(args: argsDict)
        case MCPToolDescriptor.sendMessage.name:
            payload = try await runSendMessage(args: argsDict)
        case MCPToolDescriptor.listGroupMembers.name:
            payload = try await runListGroupMembers(args: argsDict)
        case MCPToolDescriptor.createGroup.name:
            payload = try await runCreateGroup(args: argsDict)
        case MCPToolDescriptor.checkPhone.name:
            payload = try await runCheckPhone(args: argsDict)
        default:
            throw MCPError(code: -32602, message: "Unknown tool: \(toolName)")
        }

        let jsonString = try encodeJSONValueAsString(payload)
        return [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(jsonString)
                ])
            ]),
            "isError": .bool(false)
        ]
    }

    // MARK: - Tool implementations (read-only)

    func runListAccounts(args: [String: JSONValue]) async throws -> JSONValue {
        let accounts = try await storage.allAccounts()
        let array: [JSONValue] = accounts.map { account in
            .object([
                "id": .string(account.id.uuidString),
                "display_name": .string(account.displayName),
                "phone_number": jsonNullable(account.phoneNumber),
                "connection_state": .string(account.connectionState.rawValue),
                "last_connected_at": jsonNullable(account.lastConnectedAt.map(isoFormatter.string(from:)))
            ])
        }
        return .array(array)
    }

    func runListChats(args: [String: JSONValue]) async throws -> JSONValue {
        let accountID = try optionalUUID(args["account_id"], field: "account_id")
        let query = try optionalString(args["query"], field: "query")
        let limit = try clampedInt(args["limit"], field: "limit", default: 50, min: 1, max: 200)

        let chats = try await storage.chats(accountID: accountID, query: query, limit: limit)
        let array: [JSONValue] = chats.map { chat in
            .object([
                "id": .string(chat.id),
                "account_id": .string(chat.accountID.uuidString),
                "title": .string(chat.title),
                "last_message_preview": jsonNullable(chat.lastMessagePreview),
                "last_message_timestamp": jsonNullable(chat.lastMessageTimestamp.map(isoFormatter.string(from:))),
                "unread_count": .int(chat.unreadCount),
                "is_group": .bool(chat.isGroup)
            ])
        }
        return .array(array)
    }

    func runGetMessages(args: [String: JSONValue]) async throws -> JSONValue {
        guard let chatID = try optionalString(args["chat_id"], field: "chat_id"), !chatID.isEmpty else {
            throw MCPError(code: -32602, message: "Missing required parameter: chat_id")
        }
        let before = try optionalDate(args["before"], field: "before")
        let limit = try clampedInt(args["limit"], field: "limit", default: 50, min: 1, max: 200)
        let messages = try await storage.messages(chatID: chatID, before: before, limit: limit)
        return try await annotated(messages: messages)
    }

    func runSearchMessages(args: [String: JSONValue]) async throws -> JSONValue {
        guard let query = try optionalString(args["query"], field: "query"), !query.isEmpty else {
            throw MCPError(code: -32602, message: "Missing required parameter: query")
        }
        let accountID = try optionalUUID(args["account_id"], field: "account_id")
        let chatID = try optionalString(args["chat_id"], field: "chat_id")
        let limit = try clampedInt(args["limit"], field: "limit", default: 25, min: 1, max: 100)
        let messages = try await storage.search(query: query, accountID: accountID, chatID: chatID, limit: limit)
        return try await annotated(messages: messages)
    }

    /// Resolves each message's optional MediaItem ahead of JSON encoding so
    /// `messageJSON` stays synchronous. Hits a single index lookup per row —
    /// fine for the read-only tool surface which is bounded by `limit`.
    private func annotated(messages: [Message]) async throws -> JSONValue {
        var paths: [Message.ID: String] = [:]
        for message in messages {
            guard let mediaID = message.mediaID else { continue }
            if let item = try await storage.media(id: mediaID) {
                if let path = item.localPath { paths[message.id] = path }
            }
        }
        return .array(messages.map { messageJSON($0, mediaPath: paths[$0.id]) })
    }

    private func messageJSON(_ message: Message, mediaPath: String? = nil) -> JSONValue {
        .object([
            "id": .string(message.id),
            "chat_id": .string(message.chatID),
            "sender_jid": .string(message.senderJID),
            "sender_display_name": jsonNullable(message.senderDisplayName),
            "direction": .string(message.direction.rawValue),
            "kind": .string(message.kind.rawValue),
            "body": jsonNullable(message.body),
            "media_path": jsonNullable(mediaPath),
            "timestamp": .string(isoFormatter.string(from: message.timestamp)),
            "delivery_status": .string(message.deliveryStatus.rawValue)
        ])
    }

    /// Materialises a media message's bytes on disk. Returns the cached path
    /// when the SQLite mirror already has one (the helper auto-downloaded the
    /// payload on receipt). Otherwise spins up the on-demand `download_media`
    /// helper command via `WAClient.downloadMedia(messageID:)` and returns the
    /// freshly written path. `account_id` is required when no cached row
    /// exists so the server knows which helper to dispatch to.
    func runDownloadMediaNow(args: [String: JSONValue]) async throws -> JSONValue {
        guard let messageID = try optionalString(args["message_id"], field: "message_id"),
              !messageID.isEmpty
        else {
            throw MCPError(code: -32602, message: "Missing required parameter: message_id")
        }
        if let item = try await storage.media(id: messageID),
           let path = item.localPath,
           FileManager.default.fileExists(atPath: path) {
            return .object([
                "message_id": .string(messageID),
                "media_path": .string(path),
                "download_status": .string(item.downloadStatus.rawValue)
            ])
        }
        let accountID = try requiredUUID(args["account_id"], field: "account_id")
        let client = try await resolveClient(for: accountID)
        let url = try await client.downloadMedia(messageID: messageID)
        return .object([
            "message_id": .string(messageID),
            "media_path": .string(url.path),
            "download_status": .string(MediaItem.DownloadStatus.completed.rawValue)
        ])
    }

    // MARK: - Write tool implementations

    /// Dispatches `WAClient.sendMessage` for the matching account and surfaces
    /// the helper's `message_id`. Personal-use only: there is no second-level
    /// confirmation prompt — the operator authored the MCP invocation.
    func runSendMessage(args: [String: JSONValue]) async throws -> JSONValue {
        let accountID = try requiredUUID(args["account_id"], field: "account_id")
        guard let chatJID = try optionalString(args["chat_jid"], field: "chat_jid"),
              !chatJID.isEmpty
        else {
            throw MCPError(code: -32602, message: "Missing required parameter: chat_jid")
        }
        guard let text = try optionalString(args["text"], field: "text"), !text.isEmpty else {
            throw MCPError(code: -32602, message: "Missing required parameter: text")
        }
        let quoted = try optionalString(args["quoted_message_id"], field: "quoted_message_id")

        let client = try await resolveClient(for: accountID)
        let request = SendMessageRequest(
            chatJID: chatJID,
            text: text,
            mediaPath: nil,
            mediaMimeType: nil,
            caption: nil,
            quotedMessageID: quoted
        )
        let messageID = try await client.sendMessage(request)
        return .object(["message_id": .string(messageID)])
    }

    func runListGroupMembers(args: [String: JSONValue]) async throws -> JSONValue {
        let accountID = try requiredUUID(args["account_id"], field: "account_id")
        guard let chatID = try optionalString(args["chat_id"], field: "chat_id"),
              !chatID.isEmpty
        else {
            throw MCPError(code: -32602, message: "Missing required parameter: chat_id")
        }
        let client = try await resolveClient(for: accountID)
        let members = try await client.listGroupMembers(chatJID: chatID)
        let array: [JSONValue] = members.map { member in
            .object([
                "jid": .string(member.jid),
                "push_name": jsonNullable(member.pushName),
                "phone_number": jsonNullable(member.phoneNumber),
                "is_admin": .bool(member.isAdmin),
                "is_super_admin": .bool(member.isSuperAdmin)
            ])
        }
        return .object(["members": .array(array)])
    }

    func runCreateGroup(args: [String: JSONValue]) async throws -> JSONValue {
        let accountID = try requiredUUID(args["account_id"], field: "account_id")
        guard let subject = try optionalString(args["subject"], field: "subject"),
              !subject.isEmpty
        else {
            throw MCPError(code: -32602, message: "Missing required parameter: subject")
        }
        let participantsJSON = args["participant_jids"]
        guard case .array(let rawArray)? = participantsJSON else {
            throw MCPError(code: -32602, message: "participant_jids must be an array of strings")
        }
        var participants: [String] = []
        for value in rawArray {
            guard case .string(let s) = value, !s.isEmpty else {
                throw MCPError(code: -32602, message: "participant_jids must be non-empty strings")
            }
            participants.append(s)
        }
        guard !participants.isEmpty else {
            throw MCPError(code: -32602, message: "participant_jids must contain at least one entry")
        }

        let client = try await resolveClient(for: accountID)
        let created = try await client.createGroup(subject: subject, participantJIDs: participants)
        return .object([
            "chat_id": .string(created.chatID),
            "jid": .string(created.jid)
        ])
    }

    func runCheckPhone(args: [String: JSONValue]) async throws -> JSONValue {
        let accountID = try requiredUUID(args["account_id"], field: "account_id")
        guard let phone = try optionalString(args["phone_number"], field: "phone_number"),
              !phone.isEmpty
        else {
            throw MCPError(code: -32602, message: "Missing required parameter: phone_number")
        }
        let client = try await resolveClient(for: accountID)
        let result = try await client.checkPhone(phone)
        return .object([
            "phone": .string(result.phone),
            "is_on_whatsapp": .bool(result.isOnWhatsApp),
            "jid": jsonNullable(result.jid),
            "business": .bool(result.isBusiness),
            "verified_name": jsonNullable(result.verifiedName)
        ])
    }

    func runGetMessagesWithContact(args: [String: JSONValue]) async throws -> JSONValue {
        let accountID = try requiredUUID(args["account_id"], field: "account_id")
        guard let contactJID = try optionalString(args["contact_jid"], field: "contact_jid"),
              !contactJID.isEmpty
        else {
            throw MCPError(code: -32602, message: "Missing required parameter: contact_jid")
        }
        let before = try optionalDate(args["before"], field: "before")
        let limit = try clampedInt(args["limit"], field: "limit", default: 50, min: 1, max: 200)
        let messages = try await storage.messagesForContact(
            accountID: accountID,
            contactJID: contactJID,
            before: before,
            limit: limit
        )
        return try await annotated(messages: messages)
    }

    private func resolveClient(for accountID: Account.ID) async throws -> WAClient {
        guard let clientProvider else {
            throw MCPError(
                code: -32601,
                message: "Write tools are unavailable in this MCP context (no WAClient provider)"
            )
        }
        return try await clientProvider(accountID)
    }

    private func requiredUUID(_ value: JSONValue?, field: String) throws -> UUID {
        guard let uuid = try optionalUUID(value, field: field) else {
            throw MCPError(code: -32602, message: "Missing required parameter: \(field)")
        }
        return uuid
    }

    // MARK: - Parameter parsing helpers

    func optionalString(_ value: JSONValue?, field: String) throws -> String? {
        guard let value else { return nil }
        switch value {
        case .null: return nil
        case .string(let s): return s
        default:
            throw MCPError(code: -32602, message: "Invalid params: '\(field)' must be a string")
        }
    }

    func optionalUUID(_ value: JSONValue?, field: String) throws -> UUID? {
        guard let raw = try optionalString(value, field: field) else { return nil }
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPError(code: -32602, message: "Invalid params: '\(field)' must be a UUID")
        }
        return uuid
    }

    func optionalDate(_ value: JSONValue?, field: String) throws -> Date? {
        guard let raw = try optionalString(value, field: field) else { return nil }
        if let parsed = isoFormatter.date(from: raw) { return parsed }
        if let parsed = isoFormatterNoFraction.date(from: raw) { return parsed }
        throw MCPError(code: -32602, message: "Invalid params: '\(field)' must be ISO-8601")
    }

    func clampedInt(
        _ value: JSONValue?,
        field: String,
        default defaultValue: Int,
        min minValue: Int,
        max maxValue: Int
    ) throws -> Int {
        let raw: Int
        switch value {
        case .none, .null?: return defaultValue
        case .int(let n)?: raw = n
        case .double(let d)?: raw = Int(d)
        default:
            throw MCPError(code: -32602, message: "Invalid params: '\(field)' must be an integer")
        }
        if raw < minValue { return minValue }
        if raw > maxValue { return maxValue }
        return raw
    }

    // MARK: - JSON I/O

    private func writeResult(id: JSONRPCID?, result: [String: JSONValue]) throws {
        guard let id else { return } // notifications have no id and no response
        let response: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id.asJSONValue,
            "result": .object(result)
        ]
        try writeFrame(response)
    }

    private func writeError(id: JSONRPCID?, code: Int, message: String) {
        let idValue: JSONValue = id?.asJSONValue ?? .null
        let response: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": idValue,
            "error": .object([
                "code": .int(code),
                "message": .string(message)
            ])
        ]
        do {
            try writeFrame(response)
        } catch {
            logToStderr("Failed to encode error response: \(error)")
        }
    }

    private func writeFrame(_ value: [String: JSONValue]) throws {
        var data = try JSONValueEncoder.encode(.object(value))
        data.append(0x0A)
        try stdout.write(contentsOf: data)
    }

    private func logToStderr(_ message: String) {
        let line = message + "\n"
        if let data = line.data(using: .utf8) {
            try? stderr.write(contentsOf: data)
        }
        log.info("\(message, privacy: .public)")
    }

    private func encodeJSONValueAsString(_ value: JSONValue) throws -> String {
        let data = try JSONValueEncoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func jsonNullable(_ value: String?) -> JSONValue {
        guard let value else { return .null }
        return .string(value)
    }
}

// MARK: - Read-only storage facade

/// Thin facade over the same SQLite file the app writes to, opened
/// `readonly = true`. Intentionally narrower than `AppStorage` — exposes only
/// the queries the MCP tools need so the read-only contract is obvious.
public final class MCPReadOnlyStorage: @unchecked Sendable {

    private let dbPool: DatabasePool

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    public static func makeDefault() throws -> MCPReadOnlyStorage {
        let fileManager = FileManager.default
        let supportDir = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MultiverseWP", isDirectory: true)
        let dbURL = supportDir.appendingPathComponent("multiverse.sqlite")
        var config = Configuration()
        config.readonly = true
        let pool = try DatabasePool(path: dbURL.path, configuration: config)
        return MCPReadOnlyStorage(dbPool: pool)
    }

    /// Demo accounts (welcome/onboarding seeded rows) are never surfaced to MCP
    /// clients — AI assistants must only see real WhatsApp data. Every query
    /// below applies the same `is_demo = 0` filter, either directly on `account`
    /// or via a join.
    func allAccounts() async throws -> [Account] {
        try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM account WHERE is_demo = 0 ORDER BY created_at ASC"
            ).map(Self.account(from:))
        }
    }

    func chats(accountID: UUID?, query: String?, limit: Int) async throws -> [Chat] {
        try await dbPool.read { db in
            var sql = """
                SELECT c.* FROM chat c
                JOIN account a ON a.id = c.account_id
                WHERE c.is_archived = 0 AND a.is_demo = 0
                """
            var arguments: [(any DatabaseValueConvertible)?] = []
            if let accountID {
                sql += " AND c.account_id = ?"
                arguments.append(accountID.uuidString)
            }
            if let query, !query.isEmpty {
                sql += " AND (c.title LIKE ? OR c.jid LIKE ?)"
                let like = "%\(query)%"
                arguments.append(like)
                arguments.append(like)
            }
            sql += " ORDER BY c.last_message_timestamp DESC NULLS LAST, c.title ASC LIMIT ?"
            arguments.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(Self.chat(from:))
        }
    }

    func messages(chatID: String, before: Date?, limit: Int) async throws -> [Message] {
        try await dbPool.read { db in
            if let before {
                return try Row.fetchAll(
                    db,
                    sql: """
                    SELECT m.* FROM message m
                    JOIN account a ON a.id = m.account_id
                    WHERE m.chat_id = ? AND m.timestamp < ? AND m.is_deleted = 0 AND a.is_demo = 0
                    ORDER BY m.timestamp DESC LIMIT ?
                    """,
                    arguments: [chatID, before, limit]
                ).map(Self.message(from:))
            } else {
                return try Row.fetchAll(
                    db,
                    sql: """
                    SELECT m.* FROM message m
                    JOIN account a ON a.id = m.account_id
                    WHERE m.chat_id = ? AND m.is_deleted = 0 AND a.is_demo = 0
                    ORDER BY m.timestamp DESC LIMIT ?
                    """,
                    arguments: [chatID, limit]
                ).map(Self.message(from:))
            }
        }
    }

    func search(query: String, accountID: UUID?, chatID: String?, limit: Int) async throws -> [Message] {
        try await dbPool.read { db in
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
            var sql = """
                SELECT m.* FROM message m
                JOIN message_fts f ON f.message_id = m.id
                JOIN account a ON a.id = m.account_id
                WHERE message_fts MATCH ?
                AND m.is_deleted = 0
                AND a.is_demo = 0
            """
            var arguments: [(any DatabaseValueConvertible)?] = [pattern]
            if let accountID {
                sql += " AND m.account_id = ?"
                arguments.append(accountID.uuidString)
            }
            if let chatID {
                sql += " AND m.chat_id = ?"
                arguments.append(chatID)
            }
            sql += " ORDER BY rank LIMIT ?"
            arguments.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(Self.message(from:))
        }
    }

    /// Every message the operator and `contactJID` share, across every chat in
    /// the account — covers both the 1:1 thread (`chat_id = contactJID`) and
    /// the contact's contributions to group chats (`sender_jid = contactJID`).
    /// Demo accounts stay filtered out via the same `account.is_demo = 0` join
    /// the other reads use.
    func messagesForContact(
        accountID: UUID,
        contactJID: String,
        before: Date?,
        limit: Int
    ) async throws -> [Message] {
        try await dbPool.read { db in
            var sql = """
                SELECT m.* FROM message m
                JOIN account a ON a.id = m.account_id
                WHERE m.account_id = ?
                AND m.is_deleted = 0
                AND a.is_demo = 0
                AND (m.sender_jid = ? OR m.chat_id = ?)
                """
            var arguments: [(any DatabaseValueConvertible)?] = [
                accountID.uuidString,
                contactJID,
                contactJID
            ]
            if let before {
                sql += " AND m.timestamp < ?"
                arguments.append(before)
            }
            sql += " ORDER BY m.timestamp DESC LIMIT ?"
            arguments.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(Self.message(from:))
        }
    }

    /// Single-row media lookup. Mirrors `MediaRepository.media(id:)` but stays
    /// inside the read-only facade so the MCP tools cannot accidentally fall
    /// back to the writer pool.
    func media(id: String) async throws -> MediaItem? {
        try await dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM media WHERE id = ?", arguments: [id])
                .map(Self.mediaItem(from:))
        }
    }

    private static func mediaItem(from row: Row) -> MediaItem {
        MediaItem(
            id: row["id"],
            accountID: UUID(uuidString: row["account_id"]) ?? UUID(),
            mimeType: row["mime_type"],
            byteSize: row["byte_size"],
            width: row["width"],
            height: row["height"],
            durationSeconds: row["duration_seconds"],
            localPath: row["local_path"],
            remoteURL: (row["remote_url"] as String?).flatMap(URL.init(string:)),
            caption: row["caption"],
            downloadStatus: MediaItem.DownloadStatus(rawValue: row["download_status"] ?? "") ?? .pending
        )
    }

    // MARK: - Row decoding (duplicate of the private extensions in Repositories+GRDB.swift)

    private static func account(from row: Row) -> Account {
        Account(
            id: UUID(uuidString: row["id"]) ?? UUID(),
            displayName: row["display_name"],
            phoneNumber: row["phone_number"],
            jid: row["jid"],
            pushName: row["push_name"],
            avatarURL: (row["avatar_url"] as String?).flatMap(URL.init(string:)),
            connectionState: Account.ConnectionState(rawValue: row["connection_state"] ?? "") ?? .disconnected,
            createdAt: row["created_at"],
            lastConnectedAt: row["last_connected_at"],
            notificationsEnabled: row["notifications_enabled"],
            isDemo: (row["is_demo"] as Bool?) ?? false
        )
    }

    private static func chat(from row: Row) -> Chat {
        Chat(
            id: row["id"],
            accountID: UUID(uuidString: row["account_id"]) ?? UUID(),
            jid: row["jid"],
            title: row["title"],
            isGroup: row["is_group"],
            lastMessagePreview: row["last_message_preview"],
            lastMessageTimestamp: row["last_message_timestamp"],
            unreadCount: row["unread_count"],
            isMuted: row["is_muted"],
            isPinned: row["is_pinned"],
            isArchived: row["is_archived"]
        )
    }

    private static func message(from row: Row) -> Message {
        Message(
            id: row["id"],
            chatID: row["chat_id"],
            accountID: UUID(uuidString: row["account_id"]) ?? UUID(),
            senderJID: row["sender_jid"],
            senderDisplayName: row["sender_display_name"],
            direction: Message.Direction(rawValue: row["direction"] ?? "") ?? .incoming,
            kind: Message.Kind(rawValue: row["kind"] ?? "") ?? .text,
            body: row["body"],
            mediaID: row["media_id"],
            quotedMessageID: row["quoted_message_id"],
            timestamp: row["timestamp"],
            deliveryStatus: Message.DeliveryStatus(rawValue: row["delivery_status"] ?? "") ?? .pending,
            isStarred: row["is_starred"],
            isDeleted: row["is_deleted"]
        )
    }
}

// MARK: - WAClient pool for the --mcp process

/// Thread-safe lazy cache of `WAClient` instances spawned by the MCP child
/// process. The first write-tool call for an account boots its helper and
/// blocks until `connect()` resolves; subsequent calls reuse the same client.
/// The pool is intentionally separate from the GUI's `AppEnvironment` clients
/// — the `--mcp` invocation is a different process and has no access to the
/// running app's in-memory state. The downside is that two processes may
/// briefly contend on the helper's SQLite session DB; for personal use that
/// trade-off is accepted (the operator is the only invoker).
final actor MCPWAClientPool {

    private let factory: WAClientFactory
    private let keychain: KeychainStore
    private var clients: [Account.ID: WAClient] = [:]

    init(factory: WAClientFactory, keychain: KeychainStore) {
        self.factory = factory
        self.keychain = keychain
    }

    func client(for accountID: Account.ID) async throws -> WAClient {
        if let existing = clients[accountID] { return existing }
        let client = factory.makeClient(accountID: accountID, keychain: keychain)
        try await client.connect()
        clients[accountID] = client
        return client
    }
}

// MARK: - Tool descriptors

struct MCPToolDescriptor {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue

    var toolEntry: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema
        ])
    }

    static let listAccounts = MCPToolDescriptor(
        name: "list_accounts",
        title: "List linked WhatsApp accounts",
        description: "Returns every WhatsApp account currently linked to MultiverseWP. Read-only.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )

    static let listChats = MCPToolDescriptor(
        name: "list_chats",
        title: "List chats",
        description: "Lists chats, most recent first. Optional account_id and substring query filter. Read-only.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "account_id": .object([
                    "type": .string("string"),
                    "description": .string("UUID of the account to filter by. If omitted, returns chats across all accounts.")
                ]),
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Substring matched against chat title or JID.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(200),
                    "default": .int(50)
                ])
            ]),
            "additionalProperties": .bool(false)
        ])
    )

    static let getMessages = MCPToolDescriptor(
        name: "get_messages",
        title: "Get messages in a chat",
        description: "Fetches messages from one chat ordered newest-first. Use 'before' to paginate older. Read-only.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "chat_id": .object([
                    "type": .string("string"),
                    "description": .string("Chat identifier as returned by list_chats.")
                ]),
                "before": .object([
                    "type": .string("string"),
                    "format": .string("date-time"),
                    "description": .string("ISO-8601 timestamp; only messages strictly older are returned.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(200),
                    "default": .int(50)
                ])
            ]),
            "required": .array([.string("chat_id")]),
            "additionalProperties": .bool(false)
        ])
    )

    static let downloadMediaNow = MCPToolDescriptor(
        name: "download_media_now",
        title: "Download / resolve a media message",
        description: "Returns the local filesystem path for a media message (image / video / audio / document). If the bytes are already cached on disk the cached path is returned immediately; otherwise the whatsmeow helper for the supplied account_id is invoked to decrypt and persist the payload, then the freshly-written path is returned.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "message_id": .object([
                    "type": .string("string"),
                    "description": .string("Message identifier whose media payload to resolve.")
                ]),
                "account_id": .object([
                    "type": .string("string"),
                    "description": .string("Account UUID owning the message — required when the bytes are not yet cached so the helper knows which session to dispatch through.")
                ])
            ]),
            "required": .array([.string("message_id")]),
            "additionalProperties": .bool(false)
        ])
    )

    static let sendMessage = MCPToolDescriptor(
        name: "send_message",
        title: "Send a WhatsApp text message",
        description: "Sends a text message from `account_id` to `chat_jid`. Optionally quotes an existing message via `quoted_message_id`. Returns the WhatsApp-assigned `message_id`. Personal-use single-tenant: every invocation is owner-authored.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "account_id": .object([
                    "type": .string("string"),
                    "description": .string("UUID of the WhatsApp account to send from.")
                ]),
                "chat_jid": .object([
                    "type": .string("string"),
                    "description": .string("Recipient JID — either a personal JID (`...@s.whatsapp.net`) or a group JID (`...@g.us`).")
                ]),
                "text": .object([
                    "type": .string("string"),
                    "description": .string("Plain-text body to send.")
                ]),
                "quoted_message_id": .object([
                    "type": .string("string"),
                    "description": .string("Optional ID of the message to quote / reply to.")
                ])
            ]),
            "required": .array([.string("account_id"), .string("chat_jid"), .string("text")]),
            "additionalProperties": .bool(false)
        ])
    )

    static let listGroupMembers = MCPToolDescriptor(
        name: "list_group_members",
        title: "List members of a WhatsApp group",
        description: "Returns every participant of a group chat with their JID, push name, phone number, and admin / super-admin flags. Dispatches through `client.GetGroupInfo` on the matching account's helper.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "account_id": .object([
                    "type": .string("string"),
                    "description": .string("UUID of the WhatsApp account that participates in the group.")
                ]),
                "chat_id": .object([
                    "type": .string("string"),
                    "description": .string("Group chat JID (`...@g.us`).")
                ])
            ]),
            "required": .array([.string("account_id"), .string("chat_id")]),
            "additionalProperties": .bool(false)
        ])
    )

    static let createGroup = MCPToolDescriptor(
        name: "create_group",
        title: "Create a new WhatsApp group",
        description: "Creates a new group chat with the given subject and participants. Returns the resulting `chat_id` / group JID. Participant JIDs are passed in canonical `digits@s.whatsapp.net` form.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "account_id": .object([
                    "type": .string("string"),
                    "description": .string("UUID of the WhatsApp account that will own the new group.")
                ]),
                "subject": .object([
                    "type": .string("string"),
                    "description": .string("Group title (WhatsApp limits subjects to 25 characters).")
                ]),
                "participant_jids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Array of participant JIDs to add. The caller's own JID is implicit.")
                ])
            ]),
            "required": .array([.string("account_id"), .string("subject"), .string("participant_jids")]),
            "additionalProperties": .bool(false)
        ])
    )

    static let checkPhone = MCPToolDescriptor(
        name: "check_phone",
        title: "Check whether a phone number is on WhatsApp",
        description: "Resolves a phone number (E.164 or bare digits) against WhatsApp's directory. Returns `is_on_whatsapp`, the canonical JID when present, plus business / verified-name metadata when applicable.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "account_id": .object([
                    "type": .string("string"),
                    "description": .string("UUID of the WhatsApp account whose helper performs the lookup.")
                ]),
                "phone_number": .object([
                    "type": .string("string"),
                    "description": .string("Phone number in E.164 (`+90555…`) or bare digits.")
                ])
            ]),
            "required": .array([.string("account_id"), .string("phone_number")]),
            "additionalProperties": .bool(false)
        ])
    )

    static let getMessagesWithContact = MCPToolDescriptor(
        name: "get_messages_with_contact",
        title: "Get every message exchanged with a contact",
        description: "Returns messages where either the sender JID OR the chat JID matches the contact — so the result covers the 1:1 thread plus the contact's contributions to every group the operator shares with them. Read-only.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "account_id": .object([
                    "type": .string("string"),
                    "description": .string("UUID of the WhatsApp account to scope the search to.")
                ]),
                "contact_jid": .object([
                    "type": .string("string"),
                    "description": .string("Contact's WhatsApp JID (typically `digits@s.whatsapp.net`).")
                ]),
                "before": .object([
                    "type": .string("string"),
                    "format": .string("date-time"),
                    "description": .string("ISO-8601 timestamp; only messages strictly older are returned.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(200),
                    "default": .int(50)
                ])
            ]),
            "required": .array([.string("account_id"), .string("contact_jid")]),
            "additionalProperties": .bool(false)
        ])
    )

    static let searchMessages = MCPToolDescriptor(
        name: "search_messages",
        title: "Full-text search messages",
        description: "FTS5 full-text search over the local message store. Read-only.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search terms — FTS5 prefix matching is applied automatically.")
                ]),
                "account_id": .object([
                    "type": .string("string"),
                    "description": .string("Optional UUID — limits search to one account.")
                ]),
                "chat_id": .object([
                    "type": .string("string"),
                    "description": .string("Optional chat identifier — limits search to one chat.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(100),
                    "default": .int(25)
                ])
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false)
        ])
    )
}

// MARK: - JSON-RPC types

struct MCPError: Error {
    let code: Int
    let message: String
}

enum JSONRPCID: Equatable {
    case string(String)
    case int(Int)

    var asJSONValue: JSONValue {
        switch self {
        case .string(let s): return .string(s)
        case .int(let n): return .int(n)
        }
    }
}

extension JSONRPCID: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "id must be string or number")
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let n): try container.encode(n)
        }
    }
}

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: JSONValue?
}

// MARK: - JSONValue

/// Minimal JSON value tree — avoids pulling in heavyweight Codable wrappers
/// and keeps schema construction self-contained.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}

enum JSONValueEncoder {
    /// Encode without relying on Foundation `JSONEncoder` for `[String: Any]` — keys
    /// stay in the order the caller built them so debugging stdout is human-readable.
    static func encode(_ value: JSONValue) throws -> Data {
        let any = toAny(value)
        return try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
    }

    private static func toAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let n): return n
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map(toAny)
        case .object(let obj):
            var out: [String: Any] = [:]
            for (k, v) in obj { out[k] = toAny(v) }
            return out
        }
    }
}

// MARK: - Stdin line reader

/// Reads newline-delimited frames from a `FileHandle` synchronously. Blocking
/// reads are exactly what we want for stdio MCP — the client serializes
/// requests and we respond before consuming the next line.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private let newline: UInt8 = 0x0A

    init(handle: FileHandle) {
        self.handle = handle
    }

    func next() -> String? {
        while !buffer.contains(newline) {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        if let idx = buffer.firstIndex(of: newline) {
            let lineData = buffer.subdata(in: 0..<idx)
            buffer.removeSubrange(0...idx)
            return String(data: lineData, encoding: .utf8) ?? ""
        }
        if !buffer.isEmpty {
            // EOF without trailing newline — flush the remainder once.
            let lineData = buffer
            buffer.removeAll()
            return String(data: lineData, encoding: .utf8) ?? ""
        }
        return nil
    }
}

// MARK: - ISO-8601 helpers

// ISO8601DateFormatter is documented as thread-safe for parsing and formatting
// once configured, so `nonisolated(unsafe)` is correct here under strict
// concurrency — the references are immutable and the underlying object never
// mutates its `formatOptions` after init.
nonisolated(unsafe) private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

nonisolated(unsafe) private let isoFormatterNoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
