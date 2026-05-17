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

        task = Task { @MainActor [weak self] in
            do {
                try await client.connect()
            } catch {
                self?.phase = .failed(reason: error.localizedDescription)
                return
            }
            for await event in client.events {
                guard !Task.isCancelled, let self else { break }
                await self.handle(event: event, storage: storage)
                // Hand off to the long-lived MessageIngestionService once the
                // onboarding handshake is over; otherwise we'd race the
                // ingestion task on the same AsyncStream.
                switch self.phase {
                case .completed, .failed: return
                default: break
                }
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
                let cleanedPush = pushName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let existing = try await storage.accounts.allAccounts().first(where: { $0.id == id })
                let phonePrefix = String(jid.split(separator: "@").first ?? "")
                let displayName: String
                if !cleanedPush.isEmpty {
                    displayName = cleanedPush
                } else if let existing, !existing.displayName.isEmpty, existing.displayName != "My WhatsApp" {
                    displayName = existing.displayName
                } else if !phonePrefix.isEmpty {
                    displayName = "+\(phonePrefix)"
                } else {
                    displayName = "My WhatsApp"
                }
                let account = Account(
                    id: id,
                    displayName: displayName,
                    phoneNumber: phonePrefix.isEmpty ? nil : phonePrefix,
                    jid: jid,
                    pushName: cleanedPush.isEmpty ? nil : cleanedPush,
                    connectionState: .connected,
                    lastConnectedAt: Date()
                )
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
