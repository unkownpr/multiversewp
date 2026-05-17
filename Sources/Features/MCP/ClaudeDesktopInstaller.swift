import Foundation

/// Idempotently registers MultiverseWP as an MCP server in Claude Desktop's
/// config file (`~/Library/Application Support/Claude/claude_desktop_config.json`).
///
/// The merge is **non-destructive**: existing `mcpServers` entries belonging to
/// other servers are preserved; only the `multiversewp` key is created or
/// overwritten with the current executable path.
public struct ClaudeDesktopInstaller {

    public static let mcpServerKey = "multiversewp"

    public enum InstallError: Error, LocalizedError {
        case invalidExistingConfig(String)
        case ioFailure(String)

        public var errorDescription: String? {
            switch self {
            case .invalidExistingConfig(let detail):
                return "Existing Claude Desktop config is not valid JSON: \(detail)"
            case .ioFailure(let detail):
                return "Failed to write Claude Desktop config: \(detail)"
            }
        }
    }

    /// Where the helper writes by default. Override in tests to keep them hermetic.
    private let configURL: URL
    /// Absolute path the registration should point at. Defaults to the running
    /// executable, which for the bundled app is `<App>.app/Contents/MacOS/<App>`.
    private let executablePath: String

    public init(
        configURL: URL = ClaudeDesktopInstaller.defaultConfigURL(),
        executablePath: String = ClaudeDesktopInstaller.currentExecutablePath()
    ) {
        self.configURL = configURL
        self.executablePath = executablePath
    }

    public static func defaultConfigURL() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json")
    }

    public static func currentExecutablePath() -> String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "MultiverseWP"
    }

    @discardableResult
    public func install() -> Result<URL, Error> {
        do {
            try ensureDirectoryExists()
            var root = try loadExistingConfig()
            mergeServerEntry(into: &root)
            try writeConfig(root)
            return .success(configURL)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Internals

    private func ensureDirectoryExists() throws {
        let dir = configURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func loadExistingConfig() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return [:]
        }
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw InstallError.ioFailure("read failed: \(error.localizedDescription)")
        }
        if data.isEmpty { return [:] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw InstallError.invalidExistingConfig(error.localizedDescription)
        }
        guard let dict = parsed as? [String: Any] else {
            throw InstallError.invalidExistingConfig("root is not an object")
        }
        return dict
    }

    /// Merge our server entry into `root["mcpServers"]` without touching other keys.
    func mergeServerEntry(into root: inout [String: Any]) {
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers[Self.mcpServerKey] = [
            "command": executablePath,
            "args": ["--mcp"]
        ]
        root["mcpServers"] = servers
    }

    private func writeConfig(_ root: [String: Any]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw InstallError.ioFailure("serialize failed: \(error.localizedDescription)")
        }
        do {
            try data.write(to: configURL, options: [.atomic])
        } catch {
            throw InstallError.ioFailure(error.localizedDescription)
        }
    }
}
