import Foundation
import GRDB

enum Migrations {

    static func run(on writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        Self.register(in: &migrator)
        try migrator.migrate(writer)
    }

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "account") { t in
                t.column("id", .text).primaryKey()
                t.column("display_name", .text).notNull()
                t.column("phone_number", .text)
                t.column("jid", .text)
                t.column("push_name", .text)
                t.column("avatar_url", .text)
                t.column("connection_state", .text).notNull().defaults(to: "disconnected")
                t.column("created_at", .datetime).notNull()
                t.column("last_connected_at", .datetime)
                t.column("notifications_enabled", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "chat") { t in
                t.column("id", .text).primaryKey()
                t.column("account_id", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                t.column("title", .text).notNull()
                t.column("is_group", .boolean).notNull().defaults(to: false)
                t.column("last_message_preview", .text)
                t.column("last_message_timestamp", .datetime)
                t.column("unread_count", .integer).notNull().defaults(to: 0)
                t.column("is_muted", .boolean).notNull().defaults(to: false)
                t.column("is_pinned", .boolean).notNull().defaults(to: false)
                t.column("is_archived", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "chat_account_id_idx", on: "chat", columns: ["account_id"])
            try db.create(index: "chat_last_ts_idx", on: "chat", columns: ["last_message_timestamp"])

            try db.create(table: "media") { t in
                t.column("id", .text).primaryKey()
                t.column("account_id", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("mime_type", .text).notNull()
                t.column("byte_size", .integer).notNull()
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("duration_seconds", .double)
                t.column("local_path", .text)
                t.column("remote_url", .text)
                t.column("caption", .text)
                t.column("download_status", .text).notNull().defaults(to: "pending")
            }

            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()
                t.column("chat_id", .text).notNull()
                    .references("chat", onDelete: .cascade)
                t.column("account_id", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("sender_jid", .text).notNull()
                t.column("sender_display_name", .text)
                t.column("direction", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("body", .text)
                t.column("media_id", .text)
                    .references("media", onDelete: .setNull)
                t.column("quoted_message_id", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("delivery_status", .text).notNull().defaults(to: "pending")
                t.column("is_starred", .boolean).notNull().defaults(to: false)
                t.column("is_deleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "message_chat_ts_idx", on: "message", columns: ["chat_id", "timestamp"])

            try db.create(table: "contact") { t in
                t.column("id", .text).primaryKey()
                t.column("account_id", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                t.column("push_name", .text)
                t.column("business_name", .text)
                t.column("phone_number", .text)
                t.column("is_blocked", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "contact_account_jid_idx", on: "contact", columns: ["account_id", "jid"], unique: true)

            try db.create(virtualTable: "message_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.column("body")
                t.column("sender_display_name")
                t.column("message_id").notIndexed()
                t.column("chat_id").notIndexed()
                t.column("account_id").notIndexed()
            }

            try db.execute(sql: """
                CREATE TRIGGER message_fts_after_insert AFTER INSERT ON message
                WHEN NEW.body IS NOT NULL
                BEGIN
                    INSERT INTO message_fts (body, sender_display_name, message_id, chat_id, account_id)
                    VALUES (NEW.body, NEW.sender_display_name, NEW.id, NEW.chat_id, NEW.account_id);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER message_fts_after_delete AFTER DELETE ON message
                BEGIN
                    DELETE FROM message_fts WHERE message_id = OLD.id;
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER message_fts_after_update AFTER UPDATE OF body ON message
                BEGIN
                    DELETE FROM message_fts WHERE message_id = OLD.id;
                    INSERT INTO message_fts (body, sender_display_name, message_id, chat_id, account_id)
                    VALUES (NEW.body, NEW.sender_display_name, NEW.id, NEW.chat_id, NEW.account_id);
                END;
            """)
        }

        // Adds the `is_demo` flag so we can distinguish the seeded welcome
        // account from real linked WhatsApp accounts. Real rows default to
        // `false`; the seeder explicitly writes `true` for the demo account.
        migrator.registerMigration("v2_demo_flag") { db in
            try db.alter(table: "account") { t in
                t.add(column: "is_demo", .boolean).notNull().defaults(to: false)
            }
        }
    }
}
