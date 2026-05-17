import SwiftUI

struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        HStack(spacing: 0) {
            AccountSidebar()
                .ignoresSafeArea(.container, edges: .vertical)

            ChatListColumn()
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                .ignoresSafeArea(.container, edges: .vertical)

            Divider().opacity(0.3)

            ChatDetailColumn()
                .frame(minWidth: 420, maxWidth: .infinity)
                .ignoresSafeArea(.container, edges: .vertical)
        }
        .frame(minWidth: 980, minHeight: 620)
        .preferredColorScheme(.light)
        .sheet(item: $environment.pendingOnboarding) { request in
            AccountOnboardingView(request: request)
                .frame(minWidth: 520, minHeight: 580)
                .preferredColorScheme(.light)
        }
    }
}
