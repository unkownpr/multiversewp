import SwiftUI

struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @SwiftUI.AppStorage("multiversewp.sidebarHidden") private var sidebarHidden: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarHidden {
                AccountSidebar()
                    .ignoresSafeArea(.container, edges: .vertical)
                    .transition(.move(edge: .leading))
            }

            ChatListColumn()
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                .ignoresSafeArea(.container, edges: .vertical)

            Divider().opacity(0.3)

            ChatDetailColumn()
                .frame(minWidth: 420, maxWidth: .infinity)
                .ignoresSafeArea(.container, edges: .vertical)
        }
        .frame(minWidth: sidebarHidden ? 900 : 980, minHeight: 620)
        .sheet(item: $environment.pendingOnboarding) { request in
            AccountOnboardingView(request: request)
                .frame(minWidth: 520, minHeight: 580)
        }
    }
}
