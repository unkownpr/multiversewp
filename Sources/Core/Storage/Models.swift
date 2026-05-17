import Foundation

public struct Account: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = UUID

    public let id: ID
    public var displayName: String
    public var phoneNumber: String?
    public var jid: String?
    public var pushName: String?
    public var avatarURL: URL?
    public var connectionState: ConnectionState
    public var createdAt: Date
    public var lastConnectedAt: Date?
    public var notificationsEnabled: Bool

    public enum ConnectionState: String, Codable, Sendable, CaseIterable {
        case disconnected
        case awaitingQR
        case connecting
        case connected
        case unauthorized
    }

    public init(
        id: ID = UUID(),
        displayName: String,
        phoneNumber: String? = nil,
        jid: String? = nil,
        pushName: String? = nil,
        avatarURL: URL? = nil,
        connectionState: ConnectionState = .disconnected,
        createdAt: Date = .init(),
        lastConnectedAt: Date? = nil,
        notificationsEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.phoneNumber = phoneNumber
        self.jid = jid
        self.pushName = pushName
        self.avatarURL = avatarURL
        self.connectionState = connectionState
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.notificationsEnabled = notificationsEnabled
    }
}

public struct Chat: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = String

    public let id: ID
    public let accountID: Account.ID
    public var jid: String
    public var title: String
    public var isGroup: Bool
    public var lastMessagePreview: String?
    public var lastMessageTimestamp: Date?
    public var unreadCount: Int
    public var isMuted: Bool
    public var isPinned: Bool
    public var isArchived: Bool

    public init(
        id: ID,
        accountID: Account.ID,
        jid: String,
        title: String,
        isGroup: Bool = false,
        lastMessagePreview: String? = nil,
        lastMessageTimestamp: Date? = nil,
        unreadCount: Int = 0,
        isMuted: Bool = false,
        isPinned: Bool = false,
        isArchived: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.jid = jid
        self.title = title
        self.isGroup = isGroup
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageTimestamp = lastMessageTimestamp
        self.unreadCount = unreadCount
        self.isMuted = isMuted
        self.isPinned = isPinned
        self.isArchived = isArchived
    }
}

public struct Message: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = String

    public let id: ID
    public let chatID: Chat.ID
    public let accountID: Account.ID
    public var senderJID: String
    public var senderDisplayName: String?
    public var direction: Direction
    public var kind: Kind
    public var body: String?
    public var mediaID: MediaItem.ID?
    public var quotedMessageID: ID?
    public var timestamp: Date
    public var deliveryStatus: DeliveryStatus
    public var isStarred: Bool
    public var isDeleted: Bool

    public enum Direction: String, Codable, Sendable {
        case incoming
        case outgoing
    }

    public enum Kind: String, Codable, Sendable {
        case text
        case image
        case video
        case audio
        case document
        case sticker
        case location
        case contact
        case system
    }

    public enum DeliveryStatus: String, Codable, Sendable {
        case pending
        case sent
        case delivered
        case read
        case failed
    }

    public init(
        id: ID,
        chatID: Chat.ID,
        accountID: Account.ID,
        senderJID: String,
        senderDisplayName: String? = nil,
        direction: Direction,
        kind: Kind,
        body: String? = nil,
        mediaID: MediaItem.ID? = nil,
        quotedMessageID: ID? = nil,
        timestamp: Date = .init(),
        deliveryStatus: DeliveryStatus = .pending,
        isStarred: Bool = false,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.chatID = chatID
        self.accountID = accountID
        self.senderJID = senderJID
        self.senderDisplayName = senderDisplayName
        self.direction = direction
        self.kind = kind
        self.body = body
        self.mediaID = mediaID
        self.quotedMessageID = quotedMessageID
        self.timestamp = timestamp
        self.deliveryStatus = deliveryStatus
        self.isStarred = isStarred
        self.isDeleted = isDeleted
    }
}

public struct Contact: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = String

    public let id: ID
    public let accountID: Account.ID
    public var jid: String
    public var pushName: String?
    public var businessName: String?
    public var phoneNumber: String?
    public var isBlocked: Bool

    public init(
        id: ID,
        accountID: Account.ID,
        jid: String,
        pushName: String? = nil,
        businessName: String? = nil,
        phoneNumber: String? = nil,
        isBlocked: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.jid = jid
        self.pushName = pushName
        self.businessName = businessName
        self.phoneNumber = phoneNumber
        self.isBlocked = isBlocked
    }

    public var displayName: String {
        if let push = pushName, !push.isEmpty { return push }
        if let biz = businessName, !biz.isEmpty { return biz }
        if let phone = phoneNumber, !phone.isEmpty { return phone }
        return jid
    }
}

public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public typealias ID = String

    public let id: ID
    public let accountID: Account.ID
    public var mimeType: String
    public var byteSize: Int64
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var localPath: String?
    public var remoteURL: URL?
    public var caption: String?
    public var downloadStatus: DownloadStatus

    public enum DownloadStatus: String, Codable, Sendable {
        case pending
        case downloading
        case completed
        case failed
    }

    public init(
        id: ID,
        accountID: Account.ID,
        mimeType: String,
        byteSize: Int64,
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil,
        localPath: String? = nil,
        remoteURL: URL? = nil,
        caption: String? = nil,
        downloadStatus: DownloadStatus = .pending
    ) {
        self.id = id
        self.accountID = accountID
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.caption = caption
        self.downloadStatus = downloadStatus
    }
}
