import Foundation
import GRDB

private extension Account {
    init(row: Row) {
        self.init(
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

    func dbArguments() -> StatementArguments {
        [
            "id": id.uuidString,
            "display_name": displayName,
            "phone_number": phoneNumber,
            "jid": jid,
            "push_name": pushName,
            "avatar_url": avatarURL?.absoluteString,
            "connection_state": connectionState.rawValue,
            "created_at": createdAt,
            "last_connected_at": lastConnectedAt,
            "notifications_enabled": notificationsEnabled,
            "is_demo": isDemo
        ]
    }
}

private extension Chat {
    init(row: Row) {
        self.init(
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

    func dbArguments() -> StatementArguments {
        [
            "id": id,
            "account_id": accountID.uuidString,
            "jid": jid,
            "title": title,
            "is_group": isGroup,
            "last_message_preview": lastMessagePreview,
            "last_message_timestamp": lastMessageTimestamp,
            "unread_count": unreadCount,
            "is_muted": isMuted,
            "is_pinned": isPinned,
            "is_archived": isArchived
        ]
    }
}

private extension Message {
    init(row: Row) {
        self.init(
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

    func dbArguments() -> StatementArguments {
        [
            "id": id,
            "chat_id": chatID,
            "account_id": accountID.uuidString,
            "sender_jid": senderJID,
            "sender_display_name": senderDisplayName,
            "direction": direction.rawValue,
            "kind": kind.rawValue,
            "body": body,
            "media_id": mediaID,
            "quoted_message_id": quotedMessageID,
            "timestamp": timestamp,
            "delivery_status": deliveryStatus.rawValue,
            "is_starred": isStarred,
            "is_deleted": isDeleted
        ]
    }
}

private extension Contact {
    init(row: Row) {
        self.init(
            id: row["id"],
            accountID: UUID(uuidString: row["account_id"]) ?? UUID(),
            jid: row["jid"],
            pushName: row["push_name"],
            businessName: row["business_name"],
            phoneNumber: row["phone_number"],
            isBlocked: row["is_blocked"]
        )
    }

    func dbArguments() -> StatementArguments {
        [
            "id": id,
            "account_id": accountID.uuidString,
            "jid": jid,
            "push_name": pushName,
            "business_name": businessName,
            "phone_number": phoneNumber,
            "is_blocked": isBlocked
        ]
    }
}

private extension MediaItem {
    init(row: Row) {
        self.init(
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

    func dbArguments() -> StatementArguments {
        [
            "id": id,
            "account_id": accountID.uuidString,
            "mime_type": mimeType,
            "byte_size": byteSize,
            "width": width,
            "height": height,
            "duration_seconds": durationSeconds,
            "local_path": localPath,
            "remote_url": remoteURL?.absoluteString,
            "caption": caption,
            "download_status": downloadStatus.rawValue
        ]
    }
}

struct AccountsRepositoryGRDB: AccountsRepository {
    let dbPool: DatabasePool

    func allAccounts() async throws -> [Account] {
        try await dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM account ORDER BY created_at ASC").map(Account.init(row:))
        }
    }

    func upsert(_ account: Account) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO account
                (id, display_name, phone_number, jid, push_name, avatar_url, connection_state,
                 created_at, last_connected_at, notifications_enabled, is_demo)
                VALUES
                (:id, :display_name, :phone_number, :jid, :push_name, :avatar_url, :connection_state,
                 :created_at, :last_connected_at, :notifications_enabled, :is_demo)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    phone_number = excluded.phone_number,
                    jid = excluded.jid,
                    push_name = excluded.push_name,
                    avatar_url = excluded.avatar_url,
                    connection_state = excluded.connection_state,
                    last_connected_at = excluded.last_connected_at,
                    notifications_enabled = excluded.notifications_enabled,
                    is_demo = excluded.is_demo
                """,
                arguments: account.dbArguments()
            )
        }
    }

    func delete(id: Account.ID) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func updateConnectionState(_ state: Account.ConnectionState, for id: Account.ID) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE account SET connection_state = ?, last_connected_at = ? WHERE id = ?",
                arguments: [state.rawValue, state == .connected ? Date() : nil, id.uuidString]
            )
        }
    }
}

struct ChatsRepositoryGRDB: ChatsRepository {
    let dbPool: DatabasePool

    func chats(forAccount accountID: Account.ID) async throws -> [Chat] {
        try await dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM chat
                WHERE account_id = ? AND is_archived = 0
                ORDER BY is_pinned DESC, last_message_timestamp DESC NULLS LAST, title ASC
                """,
                arguments: [accountID.uuidString]
            ).map(Chat.init(row:))
        }
    }

    func chat(id: Chat.ID) async throws -> Chat? {
        try await dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM chat WHERE id = ?", arguments: [id]).map(Chat.init(row:))
        }
    }

    func upsert(_ chat: Chat) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO chat
                (id, account_id, jid, title, is_group, last_message_preview, last_message_timestamp,
                 unread_count, is_muted, is_pinned, is_archived)
                VALUES
                (:id, :account_id, :jid, :title, :is_group, :last_message_preview, :last_message_timestamp,
                 :unread_count, :is_muted, :is_pinned, :is_archived)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    is_group = excluded.is_group,
                    last_message_preview = excluded.last_message_preview,
                    last_message_timestamp = excluded.last_message_timestamp,
                    is_muted = excluded.is_muted,
                    is_pinned = excluded.is_pinned,
                    is_archived = excluded.is_archived
                """,
                arguments: chat.dbArguments()
            )
        }
    }

    func incrementUnread(for chatID: Chat.ID, by amount: Int) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE chat SET unread_count = unread_count + ? WHERE id = ?",
                arguments: [amount, chatID]
            )
        }
    }

    func resetUnread(for chatID: Chat.ID) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "UPDATE chat SET unread_count = 0 WHERE id = ?", arguments: [chatID])
        }
    }

    func totalUnread() async throws -> Int {
        try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(unread_count), 0) FROM chat") ?? 0
        }
    }
}

struct MessagesRepositoryGRDB: MessagesRepository {
    let dbPool: DatabasePool

    func messages(chatID: Chat.ID, before: Date?, limit: Int) async throws -> [Message] {
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
                ).map(Message.init(row:))
            } else {
                return try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM message
                    WHERE chat_id = ? AND is_deleted = 0
                    ORDER BY timestamp DESC LIMIT ?
                    """,
                    arguments: [chatID, limit]
                ).map(Message.init(row:))
            }
        }
    }

    func upsert(_ message: Message) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO message
                (id, chat_id, account_id, sender_jid, sender_display_name, direction, kind, body,
                 media_id, quoted_message_id, timestamp, delivery_status, is_starred, is_deleted)
                VALUES
                (:id, :chat_id, :account_id, :sender_jid, :sender_display_name, :direction, :kind, :body,
                 :media_id, :quoted_message_id, :timestamp, :delivery_status, :is_starred, :is_deleted)
                ON CONFLICT(id) DO UPDATE SET
                    body = excluded.body,
                    delivery_status = excluded.delivery_status,
                    is_starred = excluded.is_starred,
                    is_deleted = excluded.is_deleted
                """,
                arguments: message.dbArguments()
            )
        }
    }

    func updateDelivery(messageID: Message.ID, status: Message.DeliveryStatus) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE message SET delivery_status = ? WHERE id = ?",
                arguments: [status.rawValue, messageID]
            )
        }
    }

    func delete(messageID: Message.ID) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [messageID])
            try db.execute(sql: "DELETE FROM message_fts WHERE message_id = ?", arguments: [messageID])
        }
    }

    func search(text: String, accountID: Account.ID?, chatID: Chat.ID?, limit: Int) async throws -> [Message] {
        try await dbPool.read { db in
            let pattern = FTS5Pattern(matchingAllPrefixesIn: text)
            guard let pattern else { return [] }

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

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map(Message.init(row:))
        }
    }
}

struct ContactsRepositoryGRDB: ContactsRepository {
    let dbPool: DatabasePool

    func contacts(forAccount accountID: Account.ID, query: String?) async throws -> [Contact] {
        try await dbPool.read { db in
            if let query, !query.isEmpty {
                let like = "%\(query)%"
                return try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM contact
                    WHERE account_id = ?
                    AND (push_name LIKE ? OR business_name LIKE ? OR phone_number LIKE ? OR jid LIKE ?)
                    ORDER BY push_name COLLATE NOCASE ASC
                    """,
                    arguments: [accountID.uuidString, like, like, like, like]
                ).map(Contact.init(row:))
            } else {
                return try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM contact WHERE account_id = ? ORDER BY push_name COLLATE NOCASE ASC",
                    arguments: [accountID.uuidString]
                ).map(Contact.init(row:))
            }
        }
    }

    func contact(jid: String, accountID: Account.ID) async throws -> Contact? {
        try await dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM contact WHERE account_id = ? AND jid = ? LIMIT 1",
                arguments: [accountID.uuidString, jid]
            ).map(Contact.init(row:))
        }
    }

    func upsert(_ contact: Contact) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO contact
                (id, account_id, jid, push_name, business_name, phone_number, is_blocked)
                VALUES (:id, :account_id, :jid, :push_name, :business_name, :phone_number, :is_blocked)
                ON CONFLICT(id) DO UPDATE SET
                    push_name = excluded.push_name,
                    business_name = excluded.business_name,
                    phone_number = excluded.phone_number,
                    is_blocked = excluded.is_blocked
                """,
                arguments: contact.dbArguments()
            )
        }
    }
}

struct MediaRepositoryGRDB: MediaRepository {
    let dbPool: DatabasePool

    func media(id: MediaItem.ID) async throws -> MediaItem? {
        try await dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM media WHERE id = ?", arguments: [id]).map(MediaItem.init(row:))
        }
    }

    func upsert(_ item: MediaItem) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO media
                (id, account_id, mime_type, byte_size, width, height, duration_seconds,
                 local_path, remote_url, caption, download_status)
                VALUES (:id, :account_id, :mime_type, :byte_size, :width, :height, :duration_seconds,
                        :local_path, :remote_url, :caption, :download_status)
                ON CONFLICT(id) DO UPDATE SET
                    local_path = excluded.local_path,
                    download_status = excluded.download_status,
                    caption = excluded.caption
                """,
                arguments: item.dbArguments()
            )
        }
    }

    func updateDownloadStatus(id: MediaItem.ID, status: MediaItem.DownloadStatus, localPath: String?) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE media SET download_status = ?, local_path = ? WHERE id = ?",
                arguments: [status.rawValue, localPath, id]
            )
        }
    }
}
