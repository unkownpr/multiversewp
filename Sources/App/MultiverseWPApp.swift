import SwiftUI

@main
struct MultiverseWPApp: App {

    @StateObject private var environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup("MultiverseWP") {
            RootView()
                .environmentObject(environment)
                .frame(minWidth: 980, minHeight: 620)
                .task { await environment.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Account") {
                Button("Add Account…") { environment.requestAddAccount() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
