import SwiftUI

struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        HStack(spacing: 0) {
            AccountSidebar()
            ChatListColumn()
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
            Divider().opacity(0.3)
            ChatDetailColumn()
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 980, minHeight: 620)
        .ignoresSafeArea(.all, edges: .top)
        .preferredColorScheme(.light)
        .sheet(item: $environment.pendingOnboarding) { request in
            AccountOnboardingView(request: request)
                .frame(minWidth: 520, minHeight: 580)
                .preferredColorScheme(.light)
        }
    }
}
