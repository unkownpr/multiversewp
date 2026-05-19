import XCTest
@testable import MultiverseWP

@MainActor
final class MessageIngestionServiceTests: XCTestCase {

    private final class SelectionStub: MessageIngestionService.SelectionProvider {
        var selectedAccountID: Account.ID?
        var selectedChatID: Chat.ID?
        var isAppActive: Bool
        init(accountID: Account.ID?, chatID: Chat.ID?, isAppActive: Bool = true) {
            self.selectedAccountID = accountID
            self.selectedChatID = chatID
            self.isAppActive = isAppActive
        }
    }

    private func makeStorage() throws -> AppStorage {
        let storage = AppStorage.makeInMemory()
        try storage.migrateIfNeeded()
        return storage
    }

    private func makeIncoming(chatJID: String, id: String = "msg-1") -> IncomingMessage {
        IncomingMessage(
            id: id,
            chatJID: chatJID,
            senderJID: chatJID,
            senderPushName: "Peer",
            isFromMe: false,
            isGroup: false,
            kind: "text",
            body: "hello",
            mimeType: nil,
            mediaURL: nil,
            mediaByteSize: nil,
            quotedMessageID: nil,
            timestamp: Date()
        )
    }

    private func waitForUnread(
        storage: AppStorage,
        chatID: Chat.ID,
        expected: Int,
        timeout: TimeInterval = 2.0
    ) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        while Date() < deadline {
            last = try await storage.chats.chat(id: chatID)?.unreadCount ?? -1
            if last == expected { return last }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return last
    }

    func testIngestionRetainsSelectionProviderAfterAttach() async throws {
        let storage = try makeStorage()
        let ingestion = MessageIngestionService(storage: storage, eventBus: EventBus())
        let notifier = NotificationCenterBridge()

        weak var weakStub: SelectionStub?
        // Inner scope releases the strong reference at scope exit, mirroring
        // the inline `SelectionAdapter(environment: self)` call site in
        // `AppEnvironment.init`.
        do {
            let stub = SelectionStub(accountID: nil, chatID: nil)
            weakStub = stub
            ingestion.attach(selection: stub, notifier: notifier)
        }

        XCTAssertNotNil(
            weakStub,
            "MessageIngestionService must retain its SelectionProvider; otherwise isChatCurrentlyOpen always returns false."
        )
    }

    func testIncomingMessageInOpenChatDoesNotIncrementUnread() async throws {
        let storage = try makeStorage()
        let account = Account(displayName: "Test")
        try await storage.accounts.upsert(account)
        let chatJID = "open@s.whatsapp.net"

        let eventBus = EventBus()
        let ingestion = MessageIngestionService(storage: storage, eventBus: eventBus)
        let notifier = NotificationCenterBridge()
        let client = MockWAClient(accountID: account.id)

        // Inner scope releases the strong reference so the service must
        // retain the provider on its own — otherwise this regresses to the
        // pre-fix weak-ref behaviour and `isChatCurrentlyOpen` returns false.
        do {
            let stub = SelectionStub(accountID: account.id, chatID: chatJID)
            ingestion.attach(selection: stub, notifier: notifier)
        }

        ingestion.subscribe(account: account, client: client)
        client.emit(.messageReceived(makeIncoming(chatJID: chatJID)))

        // Selected chat → unread must stay 0.
        let observed = try await waitForUnread(storage: storage, chatID: chatJID, expected: 0)
        XCTAssertEqual(observed, 0, "Open chat should not accumulate unread on incoming message")
    }

    func testIncomingMessageInOpenChatTriggersServerSideMarkRead() async throws {
        let storage = try makeStorage()
        let account = Account(displayName: "Test")
        try await storage.accounts.upsert(account)
        let chatJID = "open@s.whatsapp.net"

        let eventBus = EventBus()
        let ingestion = MessageIngestionService(storage: storage, eventBus: eventBus)
        let notifier = NotificationCenterBridge()
        let client = MockWAClient(accountID: account.id)

        do {
            let stub = SelectionStub(accountID: account.id, chatID: chatJID)
            ingestion.attach(selection: stub, notifier: notifier)
        }

        ingestion.subscribe(account: account, client: client)
        client.emit(.messageReceived(makeIncoming(chatJID: chatJID)))

        // Poll the mock until the dispatched markChatRead call lands.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if client.markChatReadCalls.contains(chatJID) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            client.markChatReadCalls,
            [chatJID],
            "Active chat must propagate read receipt to WhatsApp so the peer sees blue ticks"
        )
    }

    func testIncomingMessageInBackgroundChatDoesNotMarkRead() async throws {
        let storage = try makeStorage()
        let account = Account(displayName: "Test")
        try await storage.accounts.upsert(account)
        let openJID = "open@s.whatsapp.net"
        let backgroundJID = "background@s.whatsapp.net"

        let eventBus = EventBus()
        let ingestion = MessageIngestionService(storage: storage, eventBus: eventBus)
        let notifier = NotificationCenterBridge()
        let client = MockWAClient(accountID: account.id)

        do {
            let stub = SelectionStub(accountID: account.id, chatID: openJID)
            ingestion.attach(selection: stub, notifier: notifier)
        }

        ingestion.subscribe(account: account, client: client)
        client.emit(.messageReceived(makeIncoming(chatJID: backgroundJID)))

        _ = try await waitForUnread(storage: storage, chatID: backgroundJID, expected: 1)
        XCTAssertTrue(
            client.markChatReadCalls.isEmpty,
            "Background chat must not auto-mark-read; that happens when the user opens the chat"
        )
    }

    func testBackgroundedAppIncrementsUnreadEvenForSelectedChat() async throws {
        let storage = try makeStorage()
        let account = Account(displayName: "Test")
        try await storage.accounts.upsert(account)
        let chatJID = "selected@s.whatsapp.net"

        let eventBus = EventBus()
        let ingestion = MessageIngestionService(storage: storage, eventBus: eventBus)
        let notifier = NotificationCenterBridge()
        let client = MockWAClient(accountID: account.id)

        // App not active even though the chat is still the last selected one
        // — user has Cmd-Tab'd away.
        do {
            let stub = SelectionStub(
                accountID: account.id,
                chatID: chatJID,
                isAppActive: false
            )
            ingestion.attach(selection: stub, notifier: notifier)
        }

        ingestion.subscribe(account: account, client: client)
        client.emit(.messageReceived(makeIncoming(chatJID: chatJID)))

        let observed = try await waitForUnread(storage: storage, chatID: chatJID, expected: 1)
        XCTAssertEqual(observed, 1, "Backgrounded app must still bump unread for incoming messages")
        XCTAssertTrue(
            client.markChatReadCalls.isEmpty,
            "Backgrounded app must not silently mark messages read upstream"
        )
    }

    func testIncomingMessageInOtherChatStillIncrementsUnread() async throws {
        let storage = try makeStorage()
        let account = Account(displayName: "Test")
        try await storage.accounts.upsert(account)
        let backgroundJID = "background@s.whatsapp.net"
        let openJID = "open@s.whatsapp.net"

        let eventBus = EventBus()
        let ingestion = MessageIngestionService(storage: storage, eventBus: eventBus)
        let notifier = NotificationCenterBridge()
        let client = MockWAClient(accountID: account.id)

        do {
            let stub = SelectionStub(accountID: account.id, chatID: openJID)
            ingestion.attach(selection: stub, notifier: notifier)
        }

        ingestion.subscribe(account: account, client: client)
        client.emit(.messageReceived(makeIncoming(chatJID: backgroundJID)))

        let observed = try await waitForUnread(storage: storage, chatID: backgroundJID, expected: 1)
        XCTAssertEqual(observed, 1, "Background chat must still increment unread")
    }
}
