import SwiftUI

struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationSplitView {
            AccountSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            ChatListColumn()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            ChatDetailColumn()
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $environment.pendingOnboarding) { request in
            AccountOnboardingView(request: request)
                .frame(minWidth: 480, minHeight: 520)
        }
    }
}
