import Foundation

/// Catalog of known MCP-compatible AI clients on macOS. Each entry knows
/// where its JSON config lives so MultiverseWP can drop in (or update) the
/// `multiversewp` MCP server stanza idempotently — and produce a copy-paste
/// snippet for clients whose location we don't know yet.
public struct MCPClientTarget: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let configPath: String?
    public let symbol: String
    /// One-line hint to show under the button (e.g. config file path).
    public let footnote: String

    public var configURL: URL? {
        guard let configPath else { return nil }
        let expanded = (configPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    public static let allKnown: [MCPClientTarget] = [
        MCPClientTarget(
            id: "claude_desktop",
            displayName: "Claude Desktop",
            configPath: "~/Library/Application Support/Claude/claude_desktop_config.json",
            symbol: "sparkle",
            footnote: "~/Library/Application Support/Claude/claude_desktop_config.json"
        ),
        MCPClientTarget(
            id: "claude_code",
            displayName: "Claude Code",
            configPath: "~/.claude.json",
            symbol: "terminal",
            footnote: "~/.claude.json"
        ),
        MCPClientTarget(
            id: "cursor",
            displayName: "Cursor",
            configPath: "~/.cursor/mcp.json",
            symbol: "command",
            footnote: "~/.cursor/mcp.json"
        ),
        MCPClientTarget(
            id: "continue",
            displayName: "Continue",
            configPath: "~/.continue/config.json",
            symbol: "chevron.left.forwardslash.chevron.right",
            footnote: "~/.continue/config.json"
        )
    ]
}

/// Generic installer that idempotently registers MultiverseWP as an MCP
/// server entry inside the given client's JSON config. Falls back to
/// returning the JSON snippet when no config path is available.
public struct MCPClientInstaller {

    public static let mcpServerKey = "multiversewp"

    public enum InstallError: Error, LocalizedError {
        case missingConfigPath
        case invalidExistingConfig(String)
        case ioFailure(String)

        public var errorDescription: String? {
            switch self {
            case .missingConfigPath:
                return "No known config path for this client — copy the snippet by hand."
            case .invalidExistingConfig(let detail):
                return "Existing config is not valid JSON: \(detail)"
            case .ioFailure(let detail):
                return "Failed to write client config: \(detail)"
            }
        }
    }

    public let target: MCPClientTarget
    private let executablePath: String

    public init(
        target: MCPClientTarget,
        executablePath: String = MCPClientInstaller.currentExecutablePath()
    ) {
        self.target = target
        self.executablePath = executablePath
    }

    public static func currentExecutablePath() -> String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "MultiverseWP"
    }

    /// Pretty-printed JSON the user can copy into any MCP-aware client.
    public static func snippet(executablePath: String = MCPClientInstaller.currentExecutablePath()) -> String {
        let dict: [String: Any] = [
            "mcpServers": [
                Self.mcpServerKey: [
                    "command": executablePath,
                    "args": ["--mcp"]
                ]
            ]
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    @discardableResult
    public func install() -> Result<URL, Error> {
        guard let configURL = target.configURL else {
            return .failure(InstallError.missingConfigPath)
        }
        do {
            let dir = configURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            var root = try loadExistingConfig(at: configURL)
            var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
            servers[Self.mcpServerKey] = [
                "command": executablePath,
                "args": ["--mcp"]
            ]
            root["mcpServers"] = servers
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: configURL, options: [.atomic])
            return .success(configURL)
        } catch let error as InstallError {
            return .failure(error)
        } catch {
            return .failure(InstallError.ioFailure(error.localizedDescription))
        }
    }

    private func loadExistingConfig(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw InstallError.ioFailure("read failed: \(error.localizedDescription)")
        }
        if data.isEmpty { return [:] }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if let dict = parsed as? [String: Any] { return dict }
            throw InstallError.invalidExistingConfig("root is not an object")
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.invalidExistingConfig(error.localizedDescription)
        }
    }
}
