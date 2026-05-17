import Foundation

public final class MockWAClient: WAClient, @unchecked Sendable {

    public let accountID: Account.ID
    public var events: AsyncStream<WAClientEvent> { eventStream }

    private let eventStream: AsyncStream<WAClientEvent>
    private let eventContinuation: AsyncStream<WAClientEvent>.Continuation

    public private(set) var sentMessages: [SendMessageRequest] = []
    public private(set) var connectCalls = 0

    public var sendMessageReturn: String?
    public var downloadMediaReturn: URL?

    public init(accountID: Account.ID = UUID()) {
        self.accountID = accountID
        var continuation: AsyncStream<WAClientEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    public func connect() async throws {
        connectCalls += 1
    }

    public func disconnect() async {}

    public func sendMessage(_ request: SendMessageRequest) async throws -> String {
        sentMessages.append(request)
        return sendMessageReturn ?? UUID().uuidString
    }

    public func fetchHistory(chatJID: String, limit: Int) async throws {}

    public func downloadMedia(messageID: String) async throws -> URL {
        if let downloadMediaReturn { return downloadMediaReturn }
        return URL(fileURLWithPath: "/tmp/\(messageID)")
    }

    public func markChatRead(chatJID: String) async throws {}

    public func emit(_ event: WAClientEvent) {
        eventContinuation.yield(event)
    }

    public func finish() {
        eventContinuation.finish()
    }
}
