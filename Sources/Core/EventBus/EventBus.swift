@preconcurrency import Combine
import Foundation

public enum AppEvent: Sendable {
    case accountConnected(Account.ID)
    case accountDisconnected(Account.ID)
    case messageReceived(Message)
    case messageDeliveryUpdated(messageID: Message.ID, status: Message.DeliveryStatus)
    case chatUpdated(Chat)
    case contactUpdated(Contact)
    case qrCode(accountID: Account.ID, code: String)
    case pairSuccess(accountID: Account.ID)
    case error(accountID: Account.ID?, message: String)
}

public final class EventBus: @unchecked Sendable {

    public init() {}

    private let subject = PassthroughSubject<AppEvent, Never>()

    public var publisher: AnyPublisher<AppEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    public var stream: AsyncStream<AppEvent> {
        AsyncStream { continuation in
            let cancellable = subject.sink { event in
                continuation.yield(event)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    public func publish(_ event: AppEvent) {
        subject.send(event)
    }
}
