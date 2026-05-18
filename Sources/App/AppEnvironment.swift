import Combine
import Foundation
import OSLog

@MainActor
final class AppEnvironment: ObservableObject {

    static let shared = AppEnvironment.makeDefault()

    let storage: AppStorage
    let clientFactory: WAClientFactory
    let keychain: KeychainStore
    let eventBus: EventBus
    let notifications: NotificationCenterBridge
    let ingestion: MessageIngestionService
    let log = Logger(subsystem: AppEnvironment.bundleIdentifier, category: "AppEnvironment")

    @Published var pendingOnboarding: OnboardingRequest?
    @Published var settingsOpen: Bool = false
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var selectedAccountID: Account.ID?
    @Published private(set) var selectedChatID: Chat.ID?

    static let bundleIdentifier = "com.semihsilistre.multiversewp"

    private var clients: [Account.ID: WAClient] = [:]
    private var bootstrapped = false
    private let isUITest: Bool

    init(
        storage: AppStorage,
        clientFactory: WAClientFactory,
        keychain: KeychainStore,
        eventBus: EventBus,
        isUITest: Bool = false
    ) {
        self.storage = storage
        self.clientFactory = clientFactory
        self.keychain = keychain
        self.eventBus = eventBus
        self.notifications = NotificationCenterBridge()
        self.ingestion = MessageIngestionService(
            storage: storage,
            eventBus: eventBus,
            notifier: nil,
            selection: nil
        )
        self.isUITest = isUITest
        ingestion.attach(selection: SelectionAdapter(environment: self), notifier: notifications)
    }

    static func makeDefault() -> AppEnvironment {
        let isUITest = ProcessInfo.processInfo.environment["MULTIVERSEWP_UI_TEST"] == "1"
        let storage = isUITest ? AppStorage.makeInMemory() : AppStorage.makeDefault()
        return AppEnvironment(
            storage: storage,
            clientFactory: WAClientFactory(),
            keychain: KeychainStore(service: KeychainStore.defaultService),
            eventBus: EventBus(),
            isUITest: isUITest
        )
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        do {
            try storage.migrateIfNeeded()
            try await healEmptyAccountNames()
            try await healChatTitles()
            // Seed the welcome / demo account *before* the empty-check decides
            // whether to pop the onboarding sheet, so the user always sees
            // something useful on first launch. The helper is idempotent and
            // skips itself once `multiversewp.demoSeeded` is set.
            try await seedDemoAccountIfFirstLaunch()
            accounts = try await storage.accounts.allAccounts()
            // Onboarding sheet still appears if the user only has the demo
            // account — otherwise they would think the seeded "MultiverseWP
            // Demo" entry is a real linked WhatsApp.
            if !DemoSeed.hasRealAccounts(accounts) {
                pendingOnboarding = OnboardingRequest()
            }
            selectedAccountID = accounts.first?.id
            for account in accounts where !account.isDemo {
                let client = self.client(for: account.id)
                ingestion.subscribe(account: account, client: client)
                Task { try? await client.connect() }
            }
            if !isUITest {
                await notifications.requestAuthorizationIfNeeded()
                // Best-effort GitHub Releases pull so the demo "News &
                // Updates" chat shows whatever ships in the most recent
                // tagged release. No-op on flight without a demo account
                // or when offline.
                Task { await self.refreshNewsFromGitHub() }
            }
            log.info("Bootstrap complete with \(self.accounts.count, privacy: .public) account(s)")
        } catch {
            log.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Seeds the welcome / demo account on first launch only. Tracks the
    /// "already done" state in `@AppStorage("multiversewp.demoSeeded")` so the
    /// user removing the demo from Settings → Accounts is final.
    ///
    /// Skipped under UI-test mode so the existing first-launch onboarding
    /// assertions remain deterministic.
    func seedDemoAccountIfFirstLaunch() async throws {
        if isUITest { return }
        let key = "multiversewp.demoSeeded"
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: key) { return }
        let existing = try await storage.accounts.allAccounts()
        // If a real account already exists from a previous build that
        // pre-dates this seeder, skip — we never want demo rows to appear
        // alongside live data the user has already linked.
        guard existing.isEmpty else {
            defaults.set(true, forKey: key)
            return
        }
        _ = try await DemoSeed.seed(into: storage)
        defaults.set(true, forKey: key)
        log.info("Seeded MultiverseWP demo account")
    }

    func requestAddAccount() {
        pendingOnboarding = OnboardingRequest()
    }

    func openSettings() {
        settingsOpen = true
    }

    /// Re-seed the welcome demo account on demand. No-ops if a demo
    /// account already exists; otherwise inserts a fresh one (with three
    /// pinned intro chats) and flips the persisted flag.
    func resetWelcomeTour() async {
        do {
            let all = try await storage.accounts.allAccounts()
            if !all.contains(where: { $0.isDemo }) {
                _ = try await DemoSeed.seed(into: storage)
            }
            UserDefaults.standard.set(true, forKey: "multiversewp.demoSeeded")
            await reloadAccounts()
            // Pull live news after seeding so the row is fresh.
            await refreshNewsFromGitHub()
        } catch {
            log.error("resetWelcomeTour failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Replace the demo "News & Updates" chat's messages with the latest
    /// GitHub Releases (tag, title, body, date). Safe to call repeatedly —
    /// uses the same message IDs so each fetch upserts in place.
    func refreshNewsFromGitHub() async {
        do {
            guard let demo = try await storage.accounts.allAccounts().first(where: { $0.isDemo })
            else { return }
            let chatID = "demo-news"
            guard try await storage.chats.chat(id: chatID) != nil else { return }
            let entries = await NewsFeed.fetch()
            guard !entries.isEmpty else { return }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            let sorted = entries.sorted(by: { $0.publishedAt < $1.publishedAt })
            // Replace synthetic news messages by upserting new ones with
            // stable, GitHub-tag-derived IDs.
            for (index, entry) in sorted.enumerated() {
                let body = "📢 \(entry.title) — \(formatter.string(from: entry.publishedAt))\n\n\(entry.body.trimmingCharacters(in: .whitespacesAndNewlines))"
                let message = Message(
                    id: "demo-news-gh-\(entry.tag)",
                    chatID: chatID,
                    accountID: demo.id,
                    senderJID: "demo@multiversewp",
                    senderDisplayName: "MultiverseWP",
                    direction: .incoming,
                    kind: .system,
                    body: body,
                    timestamp: entry.publishedAt.addingTimeInterval(Double(index)),
                    deliveryStatus: .delivered
                )
                try await storage.messages.upsert(message)
            }
            // Update chat preview / timestamp from the latest release.
            if let latest = sorted.last,
               var chat = try await storage.chats.chat(id: chatID) {
                chat.lastMessagePreview = "📢 \(latest.title)"
                chat.lastMessageTimestamp = latest.publishedAt
                try await storage.chats.upsert(chat)
                eventBus.publish(.chatUpdated(chat))
            }
            eventBus.publish(.accountConnected(demo.id))
        } catch {
            log.error("refreshNewsFromGitHub failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func toggleMute(chatID: Chat.ID) async {
        do {
            if var chat = try await storage.chats.chat(id: chatID) {
                chat.isMuted.toggle()
                try await storage.chats.upsert(chat)
                eventBus.publish(.chatUpdated(chat))
            }
        } catch {
            log.error("toggleMute failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func togglePin(chatID: Chat.ID) async {
        do {
            if var chat = try await storage.chats.chat(id: chatID) {
                chat.isPinned.toggle()
                try await storage.chats.upsert(chat)
                eventBus.publish(.chatUpdated(chat))
            }
        } catch {
            log.error("togglePin failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearChat(chatID: Chat.ID) async {
        do {
            if let chat = try await storage.chats.chat(id: chatID) {
                var updated = chat
                updated.lastMessagePreview = nil
                updated.lastMessageTimestamp = nil
                updated.unreadCount = 0
                try await storage.chats.upsert(updated)
                eventBus.publish(.chatUpdated(updated))
            }
        } catch {
            log.error("clearChat failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func renameAccount(_ id: Account.ID, to name: String) async {
        do {
            if var account = try await storage.accounts.allAccounts().first(where: { $0.id == id }) {
                account.displayName = name
                try await storage.accounts.upsert(account)
                await reloadAccounts()
            }
        } catch {
            log.error("rename failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeAccount(_ id: Account.ID) async {
        ingestion.unsubscribe(accountID: id)
        if let client = clients.removeValue(forKey: id) {
            await client.disconnect()
        }
        do {
            try await storage.accounts.delete(id: id)
            await reloadAccounts()
        } catch {
            log.error("remove failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-shot retitle for chats whose title was stored as the raw JID
    /// prefix (numeric phone) because the contact lookup landed *after* the
    /// chat row was first written. Run on every bootstrap so any new
    /// contact pushNames added between sessions filter through.
    private func healChatTitles() async throws {
        let accountList = try await storage.accounts.allAccounts()
        for account in accountList {
            let chats = try await storage.chats.chats(forAccount: account.id)
            for chat in chats where !chat.isGroup {
                // Self-chat ("Note to Self"): map the account's own JID.
                if let ownJid = account.jid, jidsCanonical(chat.jid) == jidsCanonical(ownJid) {
                    if chat.title != "You · Note to Self" {
                        var renamed = chat
                        renamed.title = "You · Note to Self"
                        try await storage.chats.upsert(renamed)
                    }
                    continue
                }
                guard chatTitleLooksNumeric(chat.title, jid: chat.jid) else { continue }
                if let contact = try await storage.contacts.contact(jid: chat.jid, accountID: account.id) {
                    let display = contact.displayName
                    if display != chat.jid, display != chat.title, !display.isEmpty {
                        var renamed = chat
                        renamed.title = display
                        try await storage.chats.upsert(renamed)
                        continue
                    }
                }
                // No contact record yet — at least format the bare phone as
                // "+90 555 123 45 67" style so the row is readable.
                let pretty = prettyPhone(from: chat.jid)
                if pretty != chat.title {
                    var renamed = chat
                    renamed.title = pretty
                    try await storage.chats.upsert(renamed)
                }
            }
        }
    }

    private func jidsCanonical(_ jid: String) -> String {
        let userServer = jid.split(separator: "@").first.map(String.init) ?? jid
        return String(userServer.split(separator: ":").first ?? Substring(userServer))
    }

    private func prettyPhone(from jid: String) -> String {
        let local = jidsCanonical(jid)
        guard local.allSatisfy({ $0.isNumber }), local.count >= 7 else { return jid }
        var digits = Array(local)
        // Reverse-split into groups of 2 from the right, keep the country
        // code as the leading block.
        var chunks: [String] = []
        while digits.count > 2 {
            let pair = String(digits.suffix(2))
            chunks.insert(pair, at: 0)
            digits.removeLast(2)
        }
        if !digits.isEmpty { chunks.insert(String(digits), at: 0) }
        return "+" + chunks.joined(separator: " ")
    }

    private func chatTitleLooksNumeric(_ title: String, jid: String) -> Bool {
        if title.isEmpty { return true }
        let local = String(jid.split(separator: "@").first ?? "")
        if title == local { return true }
        if title.allSatisfy({ $0.isNumber }) { return true }
        return false
    }

    /// Backfill any account whose displayName slipped through with an empty
    /// or placeholder value (early builds had a fallback bug). Try the JID
    /// phone prefix first, then push name, then a generic label.
    private func healEmptyAccountNames() async throws {
        let all = try await storage.accounts.allAccounts()
        for account in all {
            let trimmed = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlaceholder = trimmed.isEmpty || trimmed.contains(":")
            guard isPlaceholder else { continue }
            let phonePrefix = account.jid.flatMap { jid -> String in
                let userServer = String(jid.split(separator: "@").first ?? "")
                return String(userServer.split(separator: ":").first ?? Substring(userServer))
            } ?? ""
            let healed: String
            if let push = account.pushName, !push.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                healed = push
            } else if !phonePrefix.isEmpty {
                healed = "+\(phonePrefix)"
            } else {
                healed = "My WhatsApp"
            }
            var fixed = account
            fixed.displayName = healed
            try await storage.accounts.upsert(fixed)
            log.info("Healed display name for account \(account.id, privacy: .public)")
        }
    }

    func selectAccount(_ id: Account.ID?) {
        selectedAccountID = id
        selectedChatID = nil
    }

    func markAllChatsRead(for accountID: Account.ID) async {
        do {
            let chats = try await storage.chats.chats(forAccount: accountID)
            for chat in chats where chat.unreadCount > 0 {
                try await storage.chats.resetUnread(for: chat.id)
                if let refreshed = try await storage.chats.chat(id: chat.id) {
                    eventBus.publish(.chatUpdated(refreshed))
                    if let client = clients[accountID] {
                        try? await client.markChatRead(chatJID: refreshed.jid)
                    }
                }
            }
        } catch {
            log.error("markAllChatsRead failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func selectChat(_ id: Chat.ID?) {
        selectedChatID = id
        guard let id else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await storage.chats.resetUnread(for: id)
                // Republish the chat so ChatListViewModel.observe re-fetches
                // and the unread capsule disappears in real time.
                if let chat = try await storage.chats.chat(id: id) {
                    eventBus.publish(.chatUpdated(chat))
                    // Best-effort WhatsApp read receipt for incoming messages
                    // that the local store still has as unread.
                    if let client = clients[chat.accountID] {
                        try? await client.markChatRead(chatJID: chat.jid)
                    }
                }
            } catch {
                log.error("resetUnread failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func client(for accountID: Account.ID) -> WAClient {
        if let existing = clients[accountID] { return existing }
        let client = clientFactory.makeClient(accountID: accountID, keychain: keychain)
        clients[accountID] = client
        return client
    }

    func reloadAccounts() async {
        do {
            accounts = try await storage.accounts.allAccounts()
            if selectedAccountID == nil {
                selectedAccountID = accounts.first?.id
            } else if let selected = selectedAccountID,
                      !accounts.contains(where: { $0.id == selected }) {
                selectedAccountID = accounts.first?.id
            }
            for account in accounts {
                let client = self.client(for: account.id)
                // subscribe is idempotent — it cancels any prior task before
                // installing a new one, which is what we want after the
                // onboarding view-model finishes its short-lived event loop.
                ingestion.subscribe(account: account, client: client)
            }
        } catch {
            log.error("Reload accounts failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func discardOnboardingDraft(accountID: Account.ID) async {
        ingestion.unsubscribe(accountID: accountID)
        if let client = clients.removeValue(forKey: accountID) {
            await client.disconnect()
        }
        do {
            try await storage.accounts.delete(id: accountID)
            await reloadAccounts()
        } catch {
            log.error("discard draft failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct OnboardingRequest: Identifiable {
    let id = UUID()
}

private final class SelectionAdapter: MessageIngestionService.SelectionProvider, @unchecked Sendable {
    weak var environment: AppEnvironment?
    init(environment: AppEnvironment) { self.environment = environment }
    var selectedAccountID: Account.ID? { MainActor.assumeIsolated { environment?.selectedAccountID } }
    var selectedChatID: Chat.ID? { MainActor.assumeIsolated { environment?.selectedChatID } }
}
