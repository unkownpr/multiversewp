import Foundation
import GRDB
import OSLog

public protocol AccountsRepository: Sendable {
    func allAccounts() async throws -> [Account]
    func upsert(_ account: Account) async throws
    func delete(id: Account.ID) async throws
    func updateConnectionState(_ state: Account.ConnectionState, for id: Account.ID) async throws
}

public protocol ChatsRepository: Sendable {
    func chats(forAccount accountID: Account.ID) async throws -> [Chat]
    func chat(id: Chat.ID) async throws -> Chat?
    func upsert(_ chat: Chat) async throws
    func incrementUnread(for chatID: Chat.ID, by amount: Int) async throws
    func resetUnread(for chatID: Chat.ID) async throws
    func totalUnread() async throws -> Int
}

public protocol MessagesRepository: Sendable {
    func messages(chatID: Chat.ID, before: Date?, limit: Int) async throws -> [Message]
    func upsert(_ message: Message) async throws
    func updateDelivery(messageID: Message.ID, status: Message.DeliveryStatus) async throws
    func search(text: String, accountID: Account.ID?, chatID: Chat.ID?, limit: Int) async throws -> [Message]
    func delete(messageID: Message.ID) async throws
}

public protocol ContactsRepository: Sendable {
    func contacts(forAccount accountID: Account.ID, query: String?) async throws -> [Contact]
    func contact(jid: String, accountID: Account.ID) async throws -> Contact?
    func upsert(_ contact: Contact) async throws
}

public protocol MediaRepository: Sendable {
    func media(id: MediaItem.ID) async throws -> MediaItem?
    func upsert(_ item: MediaItem) async throws
    func updateDownloadStatus(id: MediaItem.ID, status: MediaItem.DownloadStatus, localPath: String?) async throws
}

public final class AppStorage: @unchecked Sendable {

    public let accounts: AccountsRepository
    public let chats: ChatsRepository
    public let messages: MessagesRepository
    public let contacts: ContactsRepository
    public let media: MediaRepository

    private let dbPool: DatabasePool
    private let log = Logger(subsystem: "com.semihsilistre.multiversewp", category: "Storage")

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
        self.accounts = AccountsRepositoryGRDB(dbPool: dbPool)
        self.chats = ChatsRepositoryGRDB(dbPool: dbPool)
        self.messages = MessagesRepositoryGRDB(dbPool: dbPool)
        self.contacts = ContactsRepositoryGRDB(dbPool: dbPool)
        self.media = MediaRepositoryGRDB(dbPool: dbPool)
    }

    public static func makeDefault() -> AppStorage {
        do {
            let fileManager = FileManager.default
            let supportDir = try fileManager
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("MultiverseWP", isDirectory: true)
            try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let dbURL = supportDir.appendingPathComponent("multiverse.sqlite")
            let pool = try DatabasePool(path: dbURL.path)
            return AppStorage(dbPool: pool)
        } catch {
            assertionFailure("Storage init failed: \(error). Falling back to in-memory store.")
            return makeInMemory()
        }
    }

    public static func makeInMemory() -> AppStorage {
        do {
            let pool = try DatabasePool.makeShared()
            return AppStorage(dbPool: pool)
        } catch {
            fatalError("Failed to bootstrap in-memory storage: \(error). This indicates a misconfigured test runner.")
        }
    }

    public func migrateIfNeeded() throws {
        try Migrations.run(on: dbPool)
        log.info("Migrations applied")
    }
}

private extension DatabasePool {
    static func makeShared() throws -> DatabasePool {
        // GRDB DatabasePool requires file path; use temp file unique per process for in-memory-like fallback.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiversewp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("test.sqlite")
        return try DatabasePool(path: url.path)
    }
}
