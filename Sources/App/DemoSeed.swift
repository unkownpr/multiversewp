import Foundation

/// First-launch seeder for the welcome / demo account.
///
/// The orchestrator's brief: when the user opens MultiverseWP and has not
/// linked any real WhatsApp account yet, we don't want to drop them straight
/// into an empty onboarding sheet. Instead we seed a single fake "MultiverseWP
/// Demo" account with three pre-populated chats that explain the app, the
/// embedded MCP server, and update channel.
///
/// Design rules:
/// - Idempotent: keyed by `@AppStorage("multiversewp.demoSeeded")`. Once the
///   user removes the demo account we never re-seed.
/// - Filtered: the rows are marked `Account.isDemo = true` so `MCPReadOnlyStorage`
///   hides them from any connected AI assistant.
/// - Distinguishable: the sidebar shows a sparkle glyph instead of the green
///   status dot — see `AccountSidebar.AccountChip`.
/// - Inert: there is no WhatsApp helper subscription attached to the demo
///   account, so it cannot send / receive real traffic.
enum DemoSeed {

    /// Seeds the welcome account into `storage` and returns the freshly built
    /// `Account` so the caller can pre-select it. No-op if the seeded flag is
    /// already set or any other account already exists.
    @discardableResult
    static func seed(into storage: AppStorage, now: Date = Date()) async throws -> Account {
        let account = Account(
            displayName: "MultiverseWP Demo",
            connectionState: .connected,
            createdAt: now.addingTimeInterval(-7 * 24 * 3_600),
            lastConnectedAt: now,
            notificationsEnabled: false,
            isDemo: true
        )
        try await storage.accounts.upsert(account)

        for chat in DemoChatSpec.allChats(accountID: account.id, now: now) {
            try await storage.chats.upsert(chat.chat)
            for message in chat.messages {
                try await storage.messages.upsert(message)
            }
        }
        return account
    }

    /// Returns true when the live store has at least one non-demo account —
    /// i.e. the user has linked a real WhatsApp. The caller uses this to decide
    /// whether the empty-accounts onboarding sheet should still appear.
    static func hasRealAccounts(_ accounts: [Account]) -> Bool {
        accounts.contains(where: { !$0.isDemo })
    }
}

// MARK: - Demo chat specs

private struct DemoChatSpec {
    let chat: Chat
    let messages: [Message]

    /// Each demo chat is built relative to `now` so the chat-list timestamps
    /// always look fresh (hours / days ago instead of a fixed January date).
    static func allChats(accountID: Account.ID, now: Date) -> [DemoChatSpec] {
        [
            welcomeChat(accountID: accountID, now: now),
            mcpChat(accountID: accountID, now: now),
            newsChat(accountID: accountID, now: now)
        ]
    }

    private static func welcomeChat(accountID: Account.ID, now: Date) -> DemoChatSpec {
        let chatID = "demo-welcome"
        let bodies: [(offsetMinutes: Double, body: String)] = [
            (-60 * 24 * 3,
             "👋 Welcome to MultiverseWP! I'm the in-app guide — these messages teach the basics in a few seconds."),
            (-60 * 24 * 3 + 2,
             "All conversations stay on your Mac. WhatsApp's end-to-end encryption is preserved — MultiverseWP never sees plaintext outside this device."),
            (-60 * 24 * 2,
             "The strip on the left holds your accounts. Each circle is one WhatsApp number. Hit the + button or ⌘⇧N to link a real account."),
            (-60 * 24 * 1,
             "The middle column is your chat list; the right pane is the open conversation. Type at the bottom and press Return to send."),
            (-60 * 6,
             "Built by Semih Silistre — ssilistre.dev. When you're ready, link a real WhatsApp from the sidebar and remove this demo from Settings → Accounts.")
        ]
        let messages = bodies.enumerated().map { index, entry in
            Message(
                id: "demo-welcome-\(index)",
                chatID: chatID,
                accountID: accountID,
                senderJID: "demo@multiversewp",
                senderDisplayName: "MultiverseWP",
                direction: .incoming,
                kind: .system,
                body: entry.body,
                timestamp: now.addingTimeInterval(entry.offsetMinutes * 60),
                deliveryStatus: .delivered
            )
        }
        let chat = Chat(
            id: chatID,
            accountID: accountID,
            jid: "welcome@multiversewp",
            title: "👋 Welcome to MultiverseWP",
            lastMessagePreview: messages.last?.body,
            lastMessageTimestamp: messages.last?.timestamp,
            isPinned: true
        )
        return DemoChatSpec(chat: chat, messages: messages)
    }

    private static func mcpChat(accountID: Account.ID, now: Date) -> DemoChatSpec {
        let chatID = "demo-mcp"
        let bodies: [(offsetMinutes: Double, body: String)] = [
            (-60 * 24 * 2,
             "🤖 MultiverseWP ships with a built-in MCP server so AI assistants can read your WhatsApp history through a strictly read-only stdio bridge."),
            (-60 * 24 * 2 + 3,
             "Four tools are exposed today: list_accounts, list_chats, get_messages, and search_messages — full-text search via SQLite FTS5."),
            (-60 * 24 + 5,
             "Launch `MultiverseWP --mcp` to attach the server to any MCP-compatible client. Settings → AI / MCP has a one-click installer for Claude Desktop."),
            (-60 * 12,
             "Coming next: send_message and download_media — both behind explicit per-chat approval prompts. No automation, ever.")
        ]
        let messages = bodies.enumerated().map { index, entry in
            Message(
                id: "demo-mcp-\(index)",
                chatID: chatID,
                accountID: accountID,
                senderJID: "demo@multiversewp",
                senderDisplayName: "MultiverseWP",
                direction: .incoming,
                kind: .system,
                body: entry.body,
                timestamp: now.addingTimeInterval(entry.offsetMinutes * 60),
                deliveryStatus: .delivered
            )
        }
        let chat = Chat(
            id: chatID,
            accountID: accountID,
            jid: "mcp@multiversewp",
            title: "🤖 MCP & AI Assistants",
            lastMessagePreview: messages.last?.body,
            lastMessageTimestamp: messages.last?.timestamp
        )
        return DemoChatSpec(chat: chat, messages: messages)
    }

    private static func newsChat(accountID: Account.ID, now: Date) -> DemoChatSpec {
        let chatID = "demo-news"
        let bodies: [(offsetMinutes: Double, body: String)] = [
            (-60 * 24 * 4,
             "📢 Phase 3 — MCP read-only server is live. Try `multiversewp --mcp` from your terminal or wire it into Claude Desktop."),
            (-60 * 24 * 2,
             "📦 Roadmap teaser: per-account notification rules, unified search across accounts, and approval-gated write tools (send_message, download_media) are next."),
            (-60 * 24 + 30,
             "🔔 Tip: check ssilistre.dev or the GitHub releases page for new builds. \"Check for updates\" lives in Settings → About."),
            (-60 * 3,
             "💚 Thanks for trying the early preview — file bugs and ideas on GitHub. Personal-use first, open-source soon.")
        ]
        let messages = bodies.enumerated().map { index, entry in
            Message(
                id: "demo-news-\(index)",
                chatID: chatID,
                accountID: accountID,
                senderJID: "demo@multiversewp",
                senderDisplayName: "MultiverseWP",
                direction: .incoming,
                kind: .system,
                body: entry.body,
                timestamp: now.addingTimeInterval(entry.offsetMinutes * 60),
                deliveryStatus: .delivered
            )
        }
        let chat = Chat(
            id: chatID,
            accountID: accountID,
            jid: "news@multiversewp",
            title: "📢 News & Updates",
            lastMessagePreview: messages.last?.body,
            lastMessageTimestamp: messages.last?.timestamp
        )
        return DemoChatSpec(chat: chat, messages: messages)
    }
}
