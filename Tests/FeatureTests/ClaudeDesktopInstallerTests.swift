import Foundation
import XCTest
@testable import MultiverseWP

final class ClaudeDesktopInstallerTests: XCTestCase {

    private var tempDir: URL!
    private var configURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-installer-\(UUID().uuidString)", isDirectory: true)
        configURL = tempDir.appendingPathComponent("Claude/claude_desktop_config.json")
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    func testInstallCreatesConfigWhenAbsent() throws {
        let installer = ClaudeDesktopInstaller(configURL: configURL, executablePath: "/Applications/MultiverseWP.app/Contents/MacOS/MultiverseWP")
        let result = installer.install()
        guard case .success(let url) = result else {
            return XCTFail("install failed: \(result)")
        }
        XCTAssertEqual(url, configURL)
        let config = try loadConfig()
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["multiversewp"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, "/Applications/MultiverseWP.app/Contents/MacOS/MultiverseWP")
        XCTAssertEqual(entry["args"] as? [String], ["--mcp"])
    }

    func testInstallPreservesOtherServers() throws {
        try writeInitialConfig([
            "mcpServers": [
                "filesystem": ["command": "/usr/local/bin/mcp-fs", "args": ["/tmp"]]
            ],
            "theme": "dark"
        ])
        let installer = ClaudeDesktopInstaller(configURL: configURL, executablePath: "/tmp/exec")
        guard case .success = installer.install() else { return XCTFail("install failed") }

        let config = try loadConfig()
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertEqual(servers.count, 2)
        XCTAssertNotNil(servers["filesystem"])
        XCTAssertNotNil(servers["multiversewp"])
        XCTAssertEqual(config["theme"] as? String, "dark")
    }

    func testInstallIsIdempotent() throws {
        let installer = ClaudeDesktopInstaller(configURL: configURL, executablePath: "/tmp/exec")
        guard case .success = installer.install() else { return XCTFail("install 1 failed") }
        let firstData = try Data(contentsOf: configURL)
        guard case .success = installer.install() else { return XCTFail("install 2 failed") }
        let secondData = try Data(contentsOf: configURL)
        XCTAssertEqual(firstData, secondData)
    }

    func testInvalidExistingConfigSurfaces() throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: configURL)
        let installer = ClaudeDesktopInstaller(configURL: configURL, executablePath: "/tmp/exec")
        if case .success = installer.install() {
            XCTFail("expected failure on corrupt config")
        }
    }

    // MARK: - Helpers

    private func writeInitialConfig(_ payload: [String: Any]) throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configURL)
    }

    private func loadConfig() throws -> [String: Any] {
        let data = try Data(contentsOf: configURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
