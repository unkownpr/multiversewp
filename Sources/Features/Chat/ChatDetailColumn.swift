import SwiftUI

struct ChatDetailColumn: View {

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = ChatDetailViewModel()

    var body: some View {
        Group {
            if let chatID = environment.selectedChatID {
                content(chatID: chatID)
            } else {
                ContentUnavailableView(
                    "Pick a chat",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a conversation from the list to read or reply.")
                )
            }
        }
        .navigationTitle(viewModel.chat?.title ?? "")
        .accessibilityIdentifier("ChatDetailColumn")
    }

    @ViewBuilder
    private func content(chatID: Chat.ID) -> some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            MessageComposer { text in
                await viewModel.sendText(text)
            }
        }
        .task(id: chatID) {
            await viewModel.load(
                chatID: chatID,
                storage: environment.storage,
                clientProvider: { environment.client(for: $0) }
            )
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

private struct MessageBubble: View {

    let message: Message

    var body: some View {
        HStack {
            if message.direction == .outgoing { Spacer() }
            VStack(alignment: message.direction == .outgoing ? .trailing : .leading, spacing: 4) {
                if message.direction == .incoming, let name = message.senderDisplayName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.body ?? mediaPlaceholder)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .foregroundStyle(textColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if message.direction == .outgoing {
                        deliveryIcon
                    }
                }
            }
            if message.direction == .incoming { Spacer() }
        }
        .accessibilityIdentifier("MessageBubble_\(message.id)")
    }

    private var bubbleBackground: Color {
        message.direction == .outgoing ? Color.accentColor : Color.secondary.opacity(0.18)
    }

    private var textColor: Color {
        message.direction == .outgoing ? .white : .primary
    }

    private var mediaPlaceholder: String {
        switch message.kind {
        case .image: "[image]"
        case .video: "[video]"
        case .audio: "[audio]"
        case .document: "[document]"
        case .sticker: "[sticker]"
        case .location: "[location]"
        case .contact: "[contact]"
        case .system: "[system]"
        case .text: ""
        }
    }

    @ViewBuilder
    private var deliveryIcon: some View {
        switch message.deliveryStatus {
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .sent: Image(systemName: "checkmark").foregroundStyle(.secondary)
        case .delivered: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .read: Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }
}
