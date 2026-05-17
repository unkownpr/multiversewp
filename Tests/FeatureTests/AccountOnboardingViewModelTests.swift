import XCTest
@testable import MultiverseWP

@MainActor
final class AccountOnboardingViewModelTests: XCTestCase {

    func testQREventTransitionsPhase() async throws {
        let storage = AppStorage.makeInMemory()
        try storage.migrateIfNeeded()
        let client = MockWAClient()

        let vm = AccountOnboardingViewModel()
        await vm.startSession(displayName: "Test", storage: storage, clientProvider: { _ in client })

        client.emit(.qrCode("WA:test-code"))
        try await waitFor { vm.phase == .awaitingQR(code: "WA:test-code") }

        let accounts = try await storage.accounts.allAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.connectionState, .awaitingQR)
    }

    func testPairSuccessCompletesPhaseAndUpdatesAccount() async throws {
        let storage = AppStorage.makeInMemory()
        try storage.migrateIfNeeded()
        let client = MockWAClient()

        let vm = AccountOnboardingViewModel()
        await vm.startSession(displayName: "Test", storage: storage, clientProvider: { _ in client })

        client.emit(.qrCode("WA:test-code"))
        client.emit(.pairSuccess(jid: "user@s.whatsapp.net", pushName: "Semih"))

        try await waitFor {
            if case .completed = vm.phase { return true }
            return false
        }
        let accounts = try await storage.accounts.allAccounts()
        XCTAssertEqual(accounts.first?.connectionState, .connected)
        XCTAssertEqual(accounts.first?.jid, "user@s.whatsapp.net")
    }

    private func waitFor(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return XCTFail("Timed out waiting for condition") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
