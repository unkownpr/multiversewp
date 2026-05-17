import SwiftUI

@main
struct MultiverseWPApp: App {

    @StateObject private var environment = AppEnvironment.shared
    @StateObject private var updater = UpdaterController()

    @SwiftUI.AppStorage("multiversewp.sidebarHidden") private var sidebarHidden: Bool = false

    init() {
        // If the process is launched as `--mcp` we never enter the SwiftUI
        // scene graph: just block on the stdio MCP server until stdin closes,
        // then exit. This keeps the MCP child process invisible (no Dock icon,
        // no window) and isolated from the running GUI instance.
        if CommandLine.arguments.contains("--mcp") {
            MultiverseWPMCPEntryPoint.runAndExit()
        }
    }

    var body: some Scene {
        WindowGroup("MultiverseWP") {
            RootView()
                .environmentObject(environment)
                .environmentObject(updater)
                .frame(minWidth: 980, minHeight: 620)
                .task { await environment.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates(nil)
                }
                .disabled(!updater.canCheckForUpdates)
            }
            CommandMenu("Account") {
                Button("Add Account…") { environment.requestAddAccount() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button(sidebarHidden ? "Show Account Sidebar" : "Hide Account Sidebar") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        sidebarHidden.toggle()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
    }
}

/// Entry point used when the binary is invoked with `--mcp`. Lives outside the
/// `App` body so it can call `exit(_:)` without confusing SwiftUI lifecycle.
enum MultiverseWPMCPEntryPoint {
    static func runAndExit() -> Never {
        do {
            let server = try MCPServer.makeProductionServer()
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await server.run()
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        } catch {
            let line = "MultiverseWP --mcp failed to start: \(error)\n"
            if let data = line.data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
            exit(1)
        }
    }
}
