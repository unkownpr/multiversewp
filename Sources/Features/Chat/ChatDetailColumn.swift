import SwiftUI

struct ChatDetailColumn: View {

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = ChatDetailViewModel()

    var body: some View {
        ZStack {
            WallpaperBackground()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("ChatDetailColumn")
    }

    @ViewBuilder
    private var content: some View {
        if let chatID = environment.selectedChatID {
            VStack(spacing: 0) {
                header(for: chatID)
                Divider().opacity(0.4)
                messageList
                composer
            }
            .task(id: chatID) {
                await viewModel.load(
                    chatID: chatID,
                    storage: environment.storage,
                    clientProvider: { environment.client(for: $0) },
                    eventBus: environment.eventBus
                )
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(WATheme.Colors.accent.opacity(0.55))
                Text("Pick a chat to start messaging")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Your conversations across every connected WhatsApp account live here.")
                    .font(.callout)
                    .foregroundStyle(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func header(for chatID: Chat.ID) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                seed: chatID,
                label: viewModel.chat?.title ?? "?",
                size: WATheme.Metrics.smallAvatarSize
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.chat?.title ?? "")
                    .font(.headline)
                Text(viewModel.chat?.isGroup == true ? "Group chat" : "online")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain)
                .help("Search in this chat")
            Button { } label: { Image(systemName: "phone") }
                .buttonStyle(.plain)
                .help("Voice call (coming soon)")
                .disabled(true)
            Button { } label: { Image(systemName: "ellipsis") }
                .buttonStyle(.plain)
                .help("More")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(WATheme.Colors.detailHeader)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .padding(.horizontal, 24)
                    }
                }
                .padding(.vertical, 14)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        MessageComposer { text in
            await viewModel.sendText(text)
        }
        .background(WATheme.Colors.detailHeader)
    }
}

private struct MessageBubble: View {

    let message: Message

    var body: some View {
        HStack {
            if message.direction == .outgoing { Spacer(minLength: 40) }
            VStack(alignment: message.direction == .outgoing ? .trailing : .leading, spacing: 2) {
                bubbleContent
                metadata
            }
            if message.direction == .incoming { Spacer(minLength: 40) }
        }
        .accessibilityIdentifier("MessageBubble_\(message.id)")
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            if message.direction == .incoming, let name = message.senderDisplayName {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WATheme.Colors.accentDark)
            }
            Text(message.body ?? placeholder)
                .font(.system(size: 14))
                .foregroundStyle(WATheme.Colors.bubbleText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            message.direction == .outgoing
                ? WATheme.Colors.outgoingBubble
                : WATheme.Colors.incomingBubble
        )
        .clipShape(BubbleShape(direction: message.direction))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            Text(timeLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if message.direction == .outgoing {
                deliveryIcon
            }
        }
        .padding(.horizontal, 6)
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: message.timestamp)
    }

    private var placeholder: String {
        switch message.kind {
        case .image: "📷 Photo"
        case .video: "🎬 Video"
        case .audio: "🎤 Voice note"
        case .document: "📄 Document"
        case .sticker: "Sticker"
        case .location: "📍 Location"
        case .contact: "👤 Contact"
        case .system: ""
        case .text: ""
        }
    }

    @ViewBuilder
    private var deliveryIcon: some View {
        switch message.deliveryStatus {
        case .pending:
            Image(systemName: "clock").imageScale(.small).foregroundStyle(.secondary)
        case .sent:
            Image(systemName: "checkmark").imageScale(.small).foregroundStyle(.secondary)
        case .delivered:
            CheckmarkPair(color: .secondary)
        case .read:
            CheckmarkPair(color: WATheme.Colors.readReceipt)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").imageScale(.small).foregroundStyle(.red)
        }
    }
}

private struct CheckmarkPair: View {
    let color: Color
    var body: some View {
        HStack(spacing: -4) {
            Image(systemName: "checkmark").imageScale(.small)
            Image(systemName: "checkmark").imageScale(.small)
        }
        .foregroundStyle(color)
    }
}

private struct BubbleShape: Shape {
    let direction: Message.Direction

    func path(in rect: CGRect) -> Path {
        let corner: CGFloat = WATheme.Metrics.bubbleCornerRadius
        let tailWidth: CGFloat = 6
        let tailHeight: CGFloat = 6
        var path = Path()

        if direction == .outgoing {
            path.move(to: CGPoint(x: corner, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX - corner, y: 0))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: corner),
                              control: CGPoint(x: rect.maxX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tailHeight))
            path.addLine(to: CGPoint(x: rect.maxX + tailWidth, y: rect.maxY))
            path.addLine(to: CGPoint(x: corner, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - corner),
                              control: CGPoint(x: 0, y: rect.maxY))
            path.addLine(to: CGPoint(x: 0, y: corner))
            path.addQuadCurve(to: CGPoint(x: corner, y: 0),
                              control: CGPoint(x: 0, y: 0))
        } else {
            path.move(to: CGPoint(x: corner, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX - corner, y: 0))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: corner),
                              control: CGPoint(x: rect.maxX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - corner, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: 0, y: rect.maxY))
            path.addLine(to: CGPoint(x: -tailWidth, y: rect.maxY))
            path.addLine(to: CGPoint(x: 0, y: rect.maxY - tailHeight))
            path.addLine(to: CGPoint(x: 0, y: corner))
            path.addQuadCurve(to: CGPoint(x: corner, y: 0),
                              control: CGPoint(x: 0, y: 0))
        }
        return path
    }
}
