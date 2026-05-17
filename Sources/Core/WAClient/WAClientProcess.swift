import Foundation
import OSLog

final class WAClientProcess: WAClient, @unchecked Sendable {

    let accountID: Account.ID

    var events: AsyncStream<WAClientEvent> { eventStream }

    private let helperLocator: HelperBinaryLocator
    private let keychain: KeychainStore
    private let log = AppLog.make("WAClient")
    private let queue = DispatchQueue(label: "com.semihsilistre.multiversewp.waclient")

    private var process: Process?
    private var stdin: FileHandle?
    private var pendingResponses: [String: CheckedContinuation<WireResponse, Error>] = [:]

    private let eventStream: AsyncStream<WAClientEvent>
    private let eventContinuation: AsyncStream<WAClientEvent>.Continuation

    init(accountID: Account.ID, helperLocator: HelperBinaryLocator, keychain: KeychainStore) {
        self.accountID = accountID
        self.helperLocator = helperLocator
        self.keychain = keychain
        var continuation: AsyncStream<WAClientEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
        process?.terminate()
    }

    func connect() async throws {
        guard process == nil else { return }
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
            self?.eventContinuation.yield(.disconnected(reason: "helper exited"))
        }

        do {
            try proc.run()
        } catch {
            throw WAClientError.helperLaunchFailed(error.localizedDescription)
        }
        process = proc
        stdin = stdinPipe.fileHandleForWriting

        startReader(stdoutPipe.fileHandleForReading)
        startStderrLogger(stderrPipe.fileHandleForReading)

        try await send(.connect)
    }

    func disconnect() async {
        try? await send(.disconnect)
        process?.terminate()
        process = nil
        stdin = nil
        eventContinuation.yield(.disconnected(reason: nil))
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
            queue.async {
                self.pendingResponses[envelope.id] = continuation
                do {
                    try self.transmit(envelope)
                } catch {
                    self.pendingResponses.removeValue(forKey: envelope.id)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func transmit(_ envelope: WireEnvelope) throws {
        guard let stdin else { throw WAClientError.notConnected }
        let data = try WireEncoder.encode(envelope)
        var payload = data
        payload.append(0x0A) // newline delimiter
        try stdin.write(contentsOf: payload)
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
            let chunk = handle.availableData
            guard !chunk.isEmpty, let string = String(data: chunk, encoding: .utf8) else { return }
            self?.log.error("helper stderr: \(string, privacy: .public)")
        }
    }

    private func process(line: Data) {
        do {
            let message = try WireDecoder.decode(line)
            switch message {
            case .response(let id, let response):
                if let continuation = pendingResponses.removeValue(forKey: id) {
                    continuation.resume(returning: response)
                }
            case .event(let event):
                eventContinuation.yield(event)
            }
        } catch {
            log.error("Decode error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
