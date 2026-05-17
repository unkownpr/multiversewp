import SwiftUI

struct ChatListColumn: View {

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = ChatListViewModel()
    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Divider().opacity(0.4)
            content
        }
        .background(WATheme.Colors.listSurface)
        .accessibilityIdentifier("ChatListColumn")
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let accountID = environment.selectedAccountID,
               let account = environment.accounts.first(where: { $0.id == accountID }) {
                AvatarView(seed: account.id.uuidString, label: account.displayName, size: WATheme.Metrics.smallAvatarSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName).font(.headline)
                    Text(statusText(for: account))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No account").font(.headline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                environment.requestAddAccount()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("New Chat / Account")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(WATheme.Colors.detailHeader)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            TextField("Search or start new chat", text: $query)
                .textFieldStyle(.plain)
                .padding(.vertical, 8)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let accountID = environment.selectedAccountID {
            list(accountID: accountID)
        } else {
            ContentUnavailableView(
                "Pick an account",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Choose an account from the sidebar.")
            )
        }
    }

    @ViewBuilder
    private func list(accountID: Account.ID) -> some View {
        if viewModel.chats.isEmpty {
            ContentUnavailableView(
                "No chats yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Conversations will land here once the account is connected.")
            )
        } else {
            List(selection: Binding(
                get: { environment.selectedChatID },
                set: { environment.selectChat($0) }
            )) {
                ForEach(viewModel.filteredChats(query: query)) { chat in
                    ChatRow(chat: chat)
                        .tag(chat.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(WATheme.Colors.listSurface)
            .task(id: accountID) {
                await viewModel.load(accountID: accountID, storage: environment.storage)
            }
        }
    }

    private func statusText(for account: Account) -> String {
        switch account.connectionState {
        case .connected: "online"
        case .connecting: "connecting…"
        case .awaitingQR: "scan QR to connect"
        case .unauthorized: "re-link required"
        case .disconnected: "offline"
        }
    }
}

private struct ChatRow: View {

    let chat: Chat

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(
                seed: chat.id,
                label: chat.title,
                size: WATheme.Metrics.avatarSize
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chat.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if chat.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let ts = chat.lastMessageTimestamp {
                        Text(timeLabel(ts))
                            .font(.caption2)
                            .foregroundStyle(chat.unreadCount > 0 ? WATheme.Colors.accent : .secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(chat.lastMessagePreview ?? "Tap to start chatting")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(WATheme.Colors.accent, in: Capsule())
                    } else if chat.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(minHeight: WATheme.Metrics.chatRowHeight)
        .accessibilityIdentifier("ChatRow_\(chat.id)")
    }

    private func timeLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let weeksAgo = calendar.dateComponents([.day], from: date, to: Date()).day, weeksAgo < 7 {
            formatter.dateFormat = "EEE"
        } else {
            formatter.dateFormat = "dd/MM/yy"
        }
        return formatter.string(from: date)
    }
}
