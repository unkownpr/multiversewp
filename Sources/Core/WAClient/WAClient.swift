import Foundation

public enum WAClientError: Error, CustomStringConvertible, Sendable {
    case helperBinaryMissing(URL?)
    case helperLaunchFailed(String)
    case decodingFailed(String)
    case notConnected
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .helperBinaryMissing(let url):
            "whatsmeow helper binary not found at \(url?.path ?? "<unknown>")"
        case .helperLaunchFailed(let reason):
            "Helper launch failed: \(reason)"
        case .decodingFailed(let reason):
            "Helper response decode failed: \(reason)"
        case .notConnected:
            "Helper not connected"
        case .invalidArgument(let reason):
            "Invalid argument: \(reason)"
        }
    }
}

public enum WAClientEvent: Sendable, Equatable {
    case qrCode(String)
    case pairSuccess(jid: String, pushName: String?)
    case connected
    case disconnected(reason: String?)
    case messageReceived(IncomingMessage)
    /// `mediaPath` is populated when the delivery transitions an existing
    /// message into a freshly-materialised media file (auto-download from the
    /// helper, an on-demand `download_media` reply, or the local copy of an
    /// outgoing send). It is nil for vanilla read/delivered receipts.
    case deliveryUpdate(messageID: String, status: String, mediaPath: String?)
    case contactUpdate(IncomingContact)
    /// Group / chat metadata refresh — emitted lazily by the helper when it
    /// learns a new title via `GetGroupInfo`. Lets the Swift side replace
    /// the placeholder JID-prefix title with the real group name.
    case chatInfo(jid: String, title: String, isGroup: Bool)
    case error(String)
}

public struct IncomingMessage: Sendable, Equatable {
    public let id: String
    public let chatJID: String
    public let senderJID: String
    public let senderPushName: String?
    public let isFromMe: Bool
    public let isGroup: Bool
    public let kind: String
    public let body: String?
    public let mimeType: String?
    public let mediaURL: String?
    public let mediaByteSize: Int64?
    /// Absolute path on the local filesystem where the helper has already
    /// materialised the decrypted media bytes. Nil when the message either has
    /// no media payload or the helper skipped auto-download (size cap, failure,
    /// or the user has not yet tapped "Download").
    public let mediaPath: String?
    public let quotedMessageID: String?
    public let timestamp: Date

    public init(
        id: String,
        chatJID: String,
        senderJID: String,
        senderPushName: String?,
        isFromMe: Bool,
        isGroup: Bool,
        kind: String,
        body: String?,
        mimeType: String?,
        mediaURL: String?,
        mediaByteSize: Int64?,
        mediaPath: String? = nil,
        quotedMessageID: String?,
        timestamp: Date
    ) {
        self.id = id
        self.chatJID = chatJID
        self.senderJID = senderJID
        self.senderPushName = senderPushName
        self.isFromMe = isFromMe
        self.isGroup = isGroup
        self.kind = kind
        self.body = body
        self.mimeType = mimeType
        self.mediaURL = mediaURL
        self.mediaByteSize = mediaByteSize
        self.mediaPath = mediaPath
        self.quotedMessageID = quotedMessageID
        self.timestamp = timestamp
    }
}

public struct IncomingContact: Sendable, Equatable {
    public let jid: String
    public let pushName: String?
    public let businessName: String?
    public let phoneNumber: String?

    public init(jid: String, pushName: String?, businessName: String?, phoneNumber: String?) {
        self.jid = jid
        self.pushName = pushName
        self.businessName = businessName
        self.phoneNumber = phoneNumber
    }
}

public struct SendMessageRequest: Sendable, Equatable {
    public let chatJID: String
    public let text: String?
    public let mediaPath: String?
    public let mediaMimeType: String?
    public let caption: String?
    public let quotedMessageID: String?

    public init(
        chatJID: String,
        text: String? = nil,
        mediaPath: String? = nil,
        mediaMimeType: String? = nil,
        caption: String? = nil,
        quotedMessageID: String? = nil
    ) {
        self.chatJID = chatJID
        self.text = text
        self.mediaPath = mediaPath
        self.mediaMimeType = mediaMimeType
        self.caption = caption
        self.quotedMessageID = quotedMessageID
    }
}

public protocol WAClient: AnyObject, Sendable {
    var accountID: Account.ID { get }
    var events: AsyncStream<WAClientEvent> { get }

    func connect() async throws
    func disconnect() async
    func sendMessage(_ request: SendMessageRequest) async throws -> String
    func fetchHistory(chatJID: String, limit: Int) async throws
    func downloadMedia(messageID: String) async throws -> URL
    func markChatRead(chatJID: String) async throws
}

public struct WAClientFactory: Sendable {

    public let helperLocator: HelperBinaryLocator

    public init(helperLocator: HelperBinaryLocator = .init()) {
        self.helperLocator = helperLocator
    }

    public func makeClient(accountID: Account.ID, keychain: KeychainStore) -> WAClient {
        WAClientProcess(
            accountID: accountID,
            helperLocator: helperLocator,
            keychain: keychain
        )
    }
}

public struct HelperBinaryLocator: Sendable {

    public init() {}

    public func resolve() -> URL? {
        if let override = ProcessInfo.processInfo.environment["WHATSMEOW_BIN"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forResource: "whatsmeow-helper", withExtension: nil) {
            return bundled
        }
        let projectFallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("WhatsmeowHelper/bin/whatsmeow-helper")
        if FileManager.default.fileExists(atPath: projectFallback.path) {
            return projectFallback
        }
        return nil
    }
}
