import SwiftUI

struct AccountSidebar: View {

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "infinity.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(WATheme.Colors.accent)
                .padding(.top, 16)
                .accessibilityHidden(true)

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(environment.accounts) { account in
                        AccountChip(
                            account: account,
                            isSelected: environment.selectedAccountID == account.id
                        ) {
                            environment.selectAccount(account.id)
                        }
                    }
                    Button {
                        environment.requestAddAccount()
                    } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(.white.opacity(0.45), style: .init(lineWidth: 1.5, dash: [4]))
                                .frame(width: WATheme.Metrics.avatarSize, height: WATheme.Metrics.avatarSize)
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Add another WhatsApp account")
                    .accessibilityLabel("Add another WhatsApp account")
                }
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)

            Image(systemName: "gearshape.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 16)
                .accessibilityLabel("Settings")
        }
        .frame(width: WATheme.Metrics.accountStripWidth)
        .background(WATheme.Colors.sidebar)
        .accessibilityIdentifier("AccountSidebar")
    }
}

private struct AccountChip: View {

    let account: Account
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    seed: account.id.uuidString,
                    label: account.displayName,
                    size: WATheme.Metrics.avatarSize
                )
                .overlay(
                    RoundedRectangle(cornerRadius: WATheme.Metrics.avatarSize / 2)
                        .stroke(isSelected ? Color.white : .clear, lineWidth: 2)
                )

                statusDot
                    .offset(x: 2, y: 2)
            }
        }
        .buttonStyle(.plain)
        .help(account.displayName)
        .accessibilityIdentifier("AccountRow_\(account.id.uuidString)")
        .accessibilityLabel(Text("\(account.displayName), \(statusLabel)"))
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(WATheme.Colors.sidebar, lineWidth: 2))
    }

    private var statusColor: Color {
        switch account.connectionState {
        case .connected: WATheme.Colors.onlineBadge
        case .connecting, .awaitingQR: .orange
        case .unauthorized: .red
        case .disconnected: .gray
        }
    }

    private var statusLabel: String {
        switch account.connectionState {
        case .disconnected: "Offline"
        case .awaitingQR: "Awaiting QR scan"
        case .connecting: "Connecting"
        case .connected: "Online"
        case .unauthorized: "Re-link required"
        }
    }
}
