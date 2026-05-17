import SwiftUI

struct ChatListColumn: View {

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = ChatListViewModel()
    @State private var query: String = ""

    var body: some View {
        Group {
            if let accountID = environment.selectedAccountID {
                content(accountID: accountID)
            } else {
                ContentUnavailableView(
                    "Select an account",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Choose an account from the sidebar to see chats.")
                )
            }
        }
        .navigationTitle("Chats")
        .searchable(text: $query, placement: .toolbar, prompt: "Search messages")
        .accessibilityIdentifier("ChatListColumn")
    }

    @ViewBuilder
    private func content(accountID: Account.ID) -> some View {
        List(selection: Binding(
            get: { environment.selectedChatID },
            set: { environment.selectChat($0) }
        )) {
            ForEach(viewModel.filteredChats(query: query)) { chat in
                ChatRow(chat: chat)
                    .tag(chat.id)
            }
        }
        .task(id: accountID) {
            await viewModel.load(accountID: accountID, storage: environment.storage)
        }
        .overlay {
            if viewModel.chats.isEmpty {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Incoming messages will appear here once the account is connected.")
                )
            }
        }
    }
}

private struct ChatRow: View {

    let chat: Chat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(chat.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let ts = chat.lastMessageTimestamp {
                        Text(ts, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(chat.lastMessagePreview ?? "No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.tint))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("ChatRow_\(chat.id)")
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(.secondary.opacity(0.25))
            Image(systemName: chat.isGroup ? "person.3.fill" : "person.fill")
                .foregroundStyle(.secondary)
        }
        .frame(width: 36, height: 36)
    }
}
