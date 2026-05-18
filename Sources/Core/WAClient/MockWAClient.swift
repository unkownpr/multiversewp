@preconcurrency import Combine
import Foundation

public final class MockWAClient: WAClient, @unchecked Sendable {

    public let accountID: Account.ID

    public var events: AsyncStream<WAClientEvent> {
        AsyncStream { continuation in
            let cancellable = subject.sink { event in
                continuation.yield(event)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    private let subject = PassthroughSubject<WAClientEvent, Never>()

    public private(set) var sentMessages: [SendMessageRequest] = []
    public private(set) var connectCalls = 0
    public private(set) var listGroupMembersCalls: [String] = []
    public private(set) var createGroupCalls: [(String, [String])] = []
    public private(set) var checkPhoneCalls: [String] = []

    public var sendMessageReturn: String?
    public var downloadMediaReturn: URL?
    public var listGroupMembersReturn: [GroupMemberInfo] = []
    public var createGroupReturn: CreatedGroupInfo?
    public var checkPhoneReturn: PhoneCheckResult?

    public init(accountID: Account.ID = UUID()) {
        self.accountID = accountID
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

    public func listGroupMembers(chatJID: String) async throws -> [GroupMemberInfo] {
        listGroupMembersCalls.append(chatJID)
        return listGroupMembersReturn
    }

    public func createGroup(subject: String, participantJIDs: [String]) async throws -> CreatedGroupInfo {
        createGroupCalls.append((subject, participantJIDs))
        return createGroupReturn ?? CreatedGroupInfo(chatID: "\(UUID().uuidString)@g.us", jid: "\(UUID().uuidString)@g.us")
    }

    public func checkPhone(_ phoneNumber: String) async throws -> PhoneCheckResult {
        checkPhoneCalls.append(phoneNumber)
        return checkPhoneReturn ?? PhoneCheckResult(
            phone: phoneNumber,
            isOnWhatsApp: false,
            jid: nil,
            isBusiness: false,
            verifiedName: nil
        )
    }

    public var subscribePresenceCalls: [String] = []
    public func subscribePresence(jid: String) async throws {
        subscribePresenceCalls.append(jid)
    }

    public func emit(_ event: WAClientEvent) {
        subject.send(event)
    }

    public func finish() {
        subject.send(completion: .finished)
    }
}
