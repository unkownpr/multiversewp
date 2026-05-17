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
            accounts = try await storage.accounts.allAccounts()
            if accounts.isEmpty {
                pendingOnboarding = OnboardingRequest()
            } else {
                selectedAccountID = accounts.first?.id
                for account in accounts {
                    let client = self.client(for: account.id)
                    ingestion.subscribe(account: account, client: client)
                    Task { try? await client.connect() }
                }
            }
            if !isUITest {
                await notifications.requestAuthorizationIfNeeded()
            }
            log.info("Bootstrap complete with \(self.accounts.count, privacy: .public) account(s)")
        } catch {
            log.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func requestAddAccount() {
        pendingOnboarding = OnboardingRequest()
    }

    func openSettings() {
        settingsOpen = true
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

    /// Backfill any account whose displayName slipped through with an empty
    /// or placeholder value (early builds had a fallback bug). Try the JID
    /// phone prefix first, then push name, then a generic label.
    private func healEmptyAccountNames() async throws {
        let all = try await storage.accounts.allAccounts()
        for account in all {
            let trimmed = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty else { continue }
            let phonePrefix = account.jid.flatMap { String($0.split(separator: "@").first ?? "") } ?? ""
            let healed: String
            if let push = account.pushName, !push.isEmpty {
                healed = push
            } else if !phonePrefix.isEmpty {
                healed = "+\(phonePrefix)"
            } else {
                healed = "My WhatsApp"
            }
            var fixed = account
            fixed.displayName = healed
            try await storage.accounts.upsert(fixed)
            log.info("Healed empty display name for account \(account.id, privacy: .public)")
        }
    }

    func selectAccount(_ id: Account.ID?) {
        selectedAccountID = id
        selectedChatID = nil
    }

    func selectChat(_ id: Chat.ID?) {
        selectedChatID = id
        guard let id else { return }
        Task {
            do {
                try await storage.chats.resetUnread(for: id)
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
