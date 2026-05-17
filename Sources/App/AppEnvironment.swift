import Combine
import Foundation
import OSLog

@MainActor
final class AppEnvironment: ObservableObject {

    static let shared = AppEnvironment(
        storage: AppStorage.makeDefault(),
        clientFactory: WAClientFactory(),
        keychain: KeychainStore(service: KeychainStore.defaultService),
        eventBus: EventBus()
    )

    let storage: AppStorage
    let clientFactory: WAClientFactory
    let keychain: KeychainStore
    let eventBus: EventBus
    let log = Logger(subsystem: AppEnvironment.bundleIdentifier, category: "AppEnvironment")

    @Published var pendingOnboarding: OnboardingRequest?
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var selectedAccountID: Account.ID?
    @Published private(set) var selectedChatID: Chat.ID?

    static let bundleIdentifier = "com.semihsilistre.multiversewp"

    private var clients: [Account.ID: WAClient] = [:]
    private var bootstrapped = false

    init(
        storage: AppStorage,
        clientFactory: WAClientFactory,
        keychain: KeychainStore,
        eventBus: EventBus
    ) {
        self.storage = storage
        self.clientFactory = clientFactory
        self.keychain = keychain
        self.eventBus = eventBus
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        do {
            try storage.migrateIfNeeded()
            accounts = try await storage.accounts.allAccounts()
            if accounts.isEmpty {
                pendingOnboarding = OnboardingRequest()
            } else {
                selectedAccountID = accounts.first?.id
            }
            log.info("Bootstrap complete with \(self.accounts.count, privacy: .public) account(s)")
        } catch {
            log.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func requestAddAccount() {
        pendingOnboarding = OnboardingRequest()
    }

    func selectAccount(_ id: Account.ID?) {
        selectedAccountID = id
        selectedChatID = nil
    }

    func selectChat(_ id: Chat.ID?) {
        selectedChatID = id
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
            if let selected = selectedAccountID,
               !accounts.contains(where: { $0.id == selected }) {
                selectedAccountID = accounts.first?.id
            }
        } catch {
            log.error("Reload accounts failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct OnboardingRequest: Identifiable {
    let id = UUID()
}
