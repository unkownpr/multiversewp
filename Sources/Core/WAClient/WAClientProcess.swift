@preconcurrency import Combine
import Foundation
import OSLog
import os

final class WAClientProcess: WAClient, @unchecked Sendable {

    let accountID: Account.ID

    /// Each access returns a fresh AsyncStream that subscribes to the shared
    /// PassthroughSubject. That lets multiple consumers (the onboarding view
    /// model AND the MessageIngestionService) observe the same helper events
    /// independently — Swift's AsyncStream is otherwise single-consumer and
    /// the second iterator would race the first.
    var events: AsyncStream<WAClientEvent> {
        AsyncStream { continuation in
            let cancellable = subject.sink { event in
                continuation.yield(event)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    private struct State {
        var process: Process?
        var stdin: FileHandle?
        var pendingResponses: [String: CheckedContinuation<WireResponse, Error>] = [:]
    }

    private let helperLocator: HelperBinaryLocator
    private let keychain: KeychainStore
    private let log = AppLog.make("WAClient")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let subject = PassthroughSubject<WAClientEvent, Never>()

    init(accountID: Account.ID, helperLocator: HelperBinaryLocator, keychain: KeychainStore) {
        self.accountID = accountID
        self.helperLocator = helperLocator
        self.keychain = keychain
    }

    deinit {
        subject.send(completion: .finished)
        state.withLock { $0.process?.terminate() }
    }

    func connect() async throws {
        let alreadyRunning = state.withLock { $0.process != nil }
        guard !alreadyRunning else { return }

        guard let url = helperLocator.resolve() else {
            throw WAClientError.helperBinaryMissing(nil)
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw WAClientError.helperBinaryMissing(url)
        }

        let sessionDir = try ensureSessionDirectory()
        let proc = Process()
        proc.executableURL = url
        proc.arguments = [
            "--account-id", accountID.uuidString,
            "--session-dir", sessionDir.path
        ]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        proc.terminationHandler = { [weak self] _ in
            self?.subject.send(.disconnected(reason: "helper exited"))
        }

        do {
            try proc.run()
        } catch {
            throw WAClientError.helperLaunchFailed(error.localizedDescription)
        }

        state.withLock {
            $0.process = proc
            $0.stdin = stdinPipe.fileHandleForWriting
        }

        startReader(stdoutPipe.fileHandleForReading)
        startStderrLogger(stderrPipe.fileHandleForReading)

        try await send(.connect)
    }

    func disconnect() async {
        try? await send(.disconnect)
        let pending: [CheckedContinuation<WireResponse, Error>] = state.withLock { state in
            state.process?.terminate()
            state.process = nil
            state.stdin = nil
            let drained = Array(state.pendingResponses.values)
            state.pendingResponses.removeAll()
            return drained
        }
        for continuation in pending {
            continuation.resume(throwing: WAClientError.notConnected)
        }
        subject.send(.disconnected(reason: nil))
    }

    func sendMessage(_ request: SendMessageRequest) async throws -> String {
        let response = try await call(.sendMessage(request))
        guard let id = response.messageID else {
            throw WAClientError.decodingFailed("send_message response missing message_id")
        }
        return id
    }

    func fetchHistory(chatJID: String, limit: Int) async throws {
        try await send(.fetchHistory(chatJID: chatJID, limit: limit))
    }

    func downloadMedia(messageID: String) async throws -> URL {
        let response = try await call(.downloadMedia(messageID: messageID))
        guard let path = response.localPath else {
            throw WAClientError.decodingFailed("download_media missing local_path")
        }
        return URL(fileURLWithPath: path)
    }

    func markChatRead(chatJID: String) async throws {
        try await send(.markRead(chatJID: chatJID))
    }

    func listGroupMembers(chatJID: String) async throws -> [GroupMemberInfo] {
        let response = try await call(.listGroupMembers(chatJID: chatJID))
        guard let extra = response.extra,
              let rawMembers = extra["members"] as? [[String: Any]]
        else {
            throw WAClientError.decodingFailed("list_group_members missing members array")
        }
        return rawMembers.map { dict in
            GroupMemberInfo(
                jid: dict["jid"] as? String ?? "",
                pushName: dict["push_name"] as? String,
                phoneNumber: dict["phone_number"] as? String,
                isAdmin: (dict["is_admin"] as? Bool) ?? false,
                isSuperAdmin: (dict["is_super_admin"] as? Bool) ?? false
            )
        }
    }

    func createGroup(subject: String, participantJIDs: [String]) async throws -> CreatedGroupInfo {
        let response = try await call(.createGroup(subject: subject, participantJIDs: participantJIDs))
        guard let extra = response.extra,
              let jid = extra["jid"] as? String,
              let chatID = extra["chat_id"] as? String
        else {
            throw WAClientError.decodingFailed("create_group missing chat_id/jid")
        }
        return CreatedGroupInfo(chatID: chatID, jid: jid)
    }

    func checkPhone(_ phoneNumber: String) async throws -> PhoneCheckResult {
        let response = try await call(.checkPhone(phoneNumber: phoneNumber))
        guard let extra = response.extra else {
            throw WAClientError.decodingFailed("check_phone missing payload")
        }
        return PhoneCheckResult(
            phone: extra["phone"] as? String ?? phoneNumber,
            isOnWhatsApp: (extra["is_on_whatsapp"] as? Bool) ?? false,
            jid: extra["jid"] as? String,
            isBusiness: (extra["business"] as? Bool) ?? false,
            verifiedName: extra["verified_name"] as? String
        )
    }

    private func ensureSessionDirectory() throws -> URL {
        let fileManager = FileManager.default
        let supportDir = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("MultiverseWP/sessions/\(accountID.uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        return supportDir
    }

    private func send(_ command: WireCommand) async throws {
        let envelope = WireEnvelope(id: UUID().uuidString, command: command)
        try transmit(envelope)
    }

    private func call(_ command: WireCommand) async throws -> WireResponse {
        let envelope = WireEnvelope(id: UUID().uuidString, command: command)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WireResponse, Error>) in
            state.withLock { $0.pendingResponses[envelope.id] = continuation }
            do {
                try transmit(envelope)
            } catch {
                let removed: CheckedContinuation<WireResponse, Error>? = state.withLock {
                    $0.pendingResponses.removeValue(forKey: envelope.id)
                }
                removed?.resume(throwing: error)
            }
        }
    }

    private func transmit(_ envelope: WireEnvelope) throws {
        let handle = state.withLock { $0.stdin }
        guard let handle else { throw WAClientError.notConnected }
        let data = try WireEncoder.encode(envelope)
        var payload = data
        payload.append(0x0A)
        do {
            try handle.write(contentsOf: payload)
        } catch {
            subject.send(.error("transmit failed: \(error.localizedDescription)"))
            throw error
        }
    }

    private func startReader(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            chunk.split(separator: 0x0A).forEach { line in
                self.process(line: Data(line))
            }
        }
    }

    private func startStderrLogger(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty, let string = String(data: chunk, encoding: .utf8) else { return }
            self.log.error("helper stderr: \(string, privacy: .public)")
        }
    }

    private func process(line: Data) {
        do {
            let message = try WireDecoder.decode(line)
            switch message {
            case .response(let id, let response):
                let continuation: CheckedContinuation<WireResponse, Error>? = state.withLock {
                    $0.pendingResponses.removeValue(forKey: id)
                }
                continuation?.resume(returning: response)
            case .event(let event):
                subject.send(event)
            }
        } catch {
            log.error("Decode error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
