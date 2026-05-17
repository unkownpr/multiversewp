import SwiftUI

struct AccountSidebar: View {

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        List(selection: Binding(
            get: { environment.selectedAccountID },
            set: { environment.selectAccount($0) }
        )) {
            Section("Accounts") {
                if environment.accounts.isEmpty {
                    EmptyAccountsRow()
                } else {
                    ForEach(environment.accounts) { account in
                        AccountRow(account: account)
                            .tag(account.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("AccountSidebar")
        .safeAreaInset(edge: .bottom) {
            Button {
                environment.requestAddAccount()
            } label: {
                Label("Add Account", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .padding(8)
        }
    }
}

private struct AccountRow: View {

    let account: Account

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.tint)
                Text(initials)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(stateColor)
            }
            Spacer()
            if account.connectionState == .connected {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.green)
            }
        }
        .accessibilityIdentifier("AccountRow_\(account.id.uuidString)")
    }

    private var initials: String {
        let words = account.displayName.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var stateLabel: String {
        switch account.connectionState {
        case .disconnected: "Offline"
        case .awaitingQR: "Scan QR"
        case .connecting: "Connecting…"
        case .connected: "Online"
        case .unauthorized: "Re-link required"
        }
    }

    private var stateColor: Color {
        switch account.connectionState {
        case .connected: .green
        case .connecting, .awaitingQR: .orange
        case .unauthorized: .red
        case .disconnected: .secondary
        }
    }
}

private struct EmptyAccountsRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No accounts yet")
                .font(.headline)
            Text("Add your first WhatsApp account to start chatting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
