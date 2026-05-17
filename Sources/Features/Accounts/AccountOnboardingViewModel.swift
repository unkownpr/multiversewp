import Foundation

@MainActor
final class AccountOnboardingViewModel: ObservableObject {

    enum Phase: Equatable {
        case preparing
        case awaitingQR(code: String)
        case pairing
        case completed(accountID: Account.ID)
        case failed(reason: String)
    }

    @Published private(set) var phase: Phase = .preparing

    public private(set) var draftAccountID: Account.ID?

    private var task: Task<Void, Never>?
    private var client: WAClient?

    deinit {
        task?.cancel()
    }

    func startSession(
        displayName: String,
        storage: AppStorage,
        clientProvider: @escaping (Account.ID) -> WAClient
    ) async {
        task?.cancel()
        phase = .preparing
        let id = UUID()
        draftAccountID = id
        let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await storage.accounts.upsert(
                Account(id: id, displayName: label.isEmpty ? "My WhatsApp" : label, connectionState: .awaitingQR)
            )
        } catch {
            phase = .failed(reason: error.localizedDescription)
            return
        }

        let client = clientProvider(id)
        self.client = client

        task = Task { [weak self] in
            do {
                try await client.connect()
            } catch {
                await MainActor.run {
                    self?.phase = .failed(reason: error.localizedDescription)
                }
                return
            }
            for await event in client.events {
                guard !Task.isCancelled else { break }
                await self?.handle(event: event, storage: storage)
            }
        }
    }

    func cancel() {
        task?.cancel()
        if let client {
            Task { await client.disconnect() }
        }
        client = nil
    }

    private func handle(event: WAClientEvent, storage: AppStorage) async {
        guard let id = draftAccountID else { return }
        switch event {
        case .qrCode(let code):
            phase = .awaitingQR(code: code)
        case .pairSuccess(let jid, let pushName):
            phase = .pairing
            do {
                var account = Account(
                    id: id,
                    displayName: pushName ?? "My WhatsApp",
                    jid: jid,
                    pushName: pushName,
                    connectionState: .connected,
                    lastConnectedAt: Date()
                )
                if pushName == nil, let existing = try await storage.accounts.allAccounts()
                    .first(where: { $0.id == id }) {
                    account.displayName = existing.displayName
                }
                try await storage.accounts.upsert(account)
                phase = .completed(accountID: id)
            } catch {
                phase = .failed(reason: error.localizedDescription)
            }
        case .connected:
            if case .awaitingQR = phase { phase = .pairing }
        case .disconnected(let reason):
            if case .completed = phase { return }
            phase = .failed(reason: reason ?? "Disconnected")
        case .error(let message):
            phase = .failed(reason: message)
        default:
            break
        }
    }
}
