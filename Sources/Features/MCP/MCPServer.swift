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

    private let options: Options
    private let storage: MCPReadOnlyStorage
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let log = Logger(subsystem: "com.semihsilistre.multiversewp", category: "MCPServer")

    public init(
        options: Options = Options(),
        storage: MCPReadOnlyStorage,
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput,
        stderr: FileHandle = .standardError
    ) {
        self.options = options
        self.storage = storage
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Convenience constructor that opens the production SQLite file at
    /// `~/Library/Application Support/MultiverseWP/multiverse.sqlite` in
    /// read-only mode.
    public static func makeProductionServer(
        options: Options = Options()
    ) throws -> MCPServer {
        let storage = try MCPReadOnlyStorage.makeDefault()
        return MCPServer(options: options, storage: storage)
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
                "Read-only access to the local MultiverseWP WhatsApp store. Sending messages "
                + "requires explicit user approval in the app — coming in a later milestone."
            )
        ]
    }

    // MARK: - Tools

    private func toolsListResult() -> [String: JSONValue] {
        let descriptors: [MCPToolDescriptor] = [
            .listAccounts, .listChats, .getMessages, .searchMessages
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
        case MCPToolDescriptor.searchMessages.name:
            payload = try await runSearchMessages(args: argsDict)
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
        return .array(messages.map(messageJSON(_:)))
    }

    func runSearchMessages(args: [String: JSONValue]) async throws -> JSONValue {
        guard let query = try optionalString(args["query"], field: "query"), !query.isEmpty else {
            throw MCPError(code: -32602, message: "Missing required parameter: query")
        }
        let accountID = try optionalUUID(args["account_id"], field: "account_id")
        let chatID = try optionalString(args["chat_id"], field: "chat_id")
        let limit = try clampedInt(args["limit"], field: "limit", default: 25, min: 1, max: 100)
        let messages = try await storage.search(query: query, accountID: accountID, chatID: chatID, limit: limit)
        return .array(messages.map(messageJSON(_:)))
    }

    private func messageJSON(_ message: Message) -> JSONValue {
        .object([
            "id": .string(message.id),
            "chat_id": .string(message.chatID),
            "sender_jid": .string(message.senderJID),
            "sender_display_name": jsonNullable(message.senderDisplayName),
            "direction": .string(message.direction.rawValue),
            "kind": .string(message.kind.rawValue),
            "body": jsonNullable(message.body),
            "timestamp": .string(isoFormatter.string(from: message.timestamp)),
            "delivery_status": .string(message.deliveryStatus.rawValue)
        ])
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

    func allAccounts() async throws -> [Account] {
        try await dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM account ORDER BY created_at ASC").map(Self.account(from:))
        }
    }

    func chats(accountID: UUID?, query: String?, limit: Int) async throws -> [Chat] {
        try await dbPool.read { db in
            var sql = "SELECT * FROM chat WHERE is_archived = 0"
            var arguments: [(any DatabaseValueConvertible)?] = []
            if let accountID {
                sql += " AND account_id = ?"
                arguments.append(accountID.uuidString)
            }
            if let query, !query.isEmpty {
                sql += " AND (title LIKE ? OR jid LIKE ?)"
                let like = "%\(query)%"
                arguments.append(like)
                arguments.append(like)
            }
            sql += " ORDER BY last_message_timestamp DESC NULLS LAST, title ASC LIMIT ?"
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
                    SELECT * FROM message
                    WHERE chat_id = ? AND timestamp < ? AND is_deleted = 0
                    ORDER BY timestamp DESC LIMIT ?
                    """,
                    arguments: [chatID, before, limit]
                ).map(Self.message(from:))
            } else {
                return try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM message
                    WHERE chat_id = ? AND is_deleted = 0
                    ORDER BY timestamp DESC LIMIT ?
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
                WHERE message_fts MATCH ?
                AND m.is_deleted = 0
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
            notificationsEnabled: row["notifications_enabled"]
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

    static let searchMessages = MCPToolDescriptor(
        name: "search_messages",
        title: "Full-text search messages",
        description: "FTS5 full-text search over the local message store. Read-only. Sending messages requires explicit user approval in the app — coming in a later milestone.",
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
