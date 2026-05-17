import Combine
import XCTest
@testable import MultiverseWP

final class EventBusTests: XCTestCase {

    func testPublishDeliversToCombineSubscriber() {
        let bus = EventBus()
        let expectation = expectation(description: "event delivered")
        var received: AppEvent?

        var cancellables: Set<AnyCancellable> = []
        bus.publisher
            .sink { event in
                received = event
                expectation.fulfill()
            }
            .store(in: &cancellables)

        bus.publish(.accountConnected(UUID()))
        wait(for: [expectation], timeout: 1.0)
        if case .accountConnected = received {
            // OK
        } else {
            XCTFail("Expected accountConnected, got \(String(describing: received))")
        }
    }
}
