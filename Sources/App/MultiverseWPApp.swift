import SwiftUI

@main
struct MultiverseWPApp: App {

    @StateObject private var environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup("MultiverseWP") {
            RootView()
                .environmentObject(environment)
                .frame(minWidth: 900, minHeight: 600)
                .task { await environment.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Account") {
                Button("Add Account…") { environment.requestAddAccount() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
