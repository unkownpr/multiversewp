import AVFoundation
import AppKit
import SwiftUI

struct ChatDetailColumn: View {

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel = ChatDetailViewModel()

    var body: some View {
        ZStack {
            WallpaperBackground()
            content
        }
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
                        MessageBubble(
                            message: message,
                            media: viewModel.media[message.id],
                            onDownload: { id in
                                Task { await viewModel.downloadMedia(for: id) }
                            }
                        )
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
        MessageComposer(
            onSend: { text in
                await viewModel.sendText(text)
            },
            onSendAttachment: { text, attachment in
                await viewModel.sendAttachment(text: text, attachment: attachment)
            }
        )
        .background(WATheme.Colors.detailHeader)
    }
}

private struct MessageBubble: View {

    let message: Message
    let media: MediaItem?
    let onDownload: (Message.ID) -> Void

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

    private var hasLocalMedia: Bool {
        guard let path = media?.localPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.direction == .incoming, let name = message.senderDisplayName {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WATheme.Colors.accentDark)
            }
            mediaView
            if let body = message.body, !body.isEmpty {
                Text(body)
                    .font(.system(size: 14))
                    .foregroundStyle(WATheme.Colors.bubbleText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !hasLocalMedia, message.kind == .text {
                Text(placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(WATheme.Colors.bubbleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    @ViewBuilder
    private var mediaView: some View {
        switch message.kind {
        case .image:
            if let path = media?.localPath, FileManager.default.fileExists(atPath: path),
               let image = NSImage(byReferencingFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .accessibilityIdentifier("MessageBubbleImage_\(message.id)")
            } else {
                mediaPlaceholder(symbol: "photo", label: "Photo")
            }
        case .video:
            if let path = media?.localPath, FileManager.default.fileExists(atPath: path) {
                VideoThumbView(filePath: path)
                    .frame(maxWidth: 320, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .accessibilityIdentifier("MessageBubbleVideo_\(message.id)")
            } else {
                mediaPlaceholder(symbol: "film", label: "Video")
            }
        case .audio:
            if let path = media?.localPath, FileManager.default.fileExists(atPath: path) {
                AudioPlayerPill(filePath: path)
                    .accessibilityIdentifier("MessageBubbleAudio_\(message.id)")
            } else {
                mediaPlaceholder(symbol: "waveform", label: "Voice note")
            }
        case .document:
            if let path = media?.localPath, FileManager.default.fileExists(atPath: path) {
                DocumentChip(filePath: path)
                    .accessibilityIdentifier("MessageBubbleDocument_\(message.id)")
            } else {
                mediaPlaceholder(symbol: "doc", label: media?.caption ?? "Document")
            }
        case .sticker:
            if let path = media?.localPath, FileManager.default.fileExists(atPath: path),
               let image = NSImage(byReferencingFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
            } else {
                mediaPlaceholder(symbol: "face.smiling", label: "Sticker")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func mediaPlaceholder(symbol: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WATheme.Colors.bubbleText)
                if let size = media?.byteSize, size > 0 {
                    Text(byteCountFormatter.string(fromByteCount: size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if message.kind != .text, message.kind != .system {
                Button("Download") {
                    onDownload(message.id)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityIdentifier("MessageBubbleDownload_\(message.id)")
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 280)
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

/// Renders a static thumbnail for a local video file with a play badge. The
/// frame is generated lazily via `AVAssetImageGenerator` and cached on disk as
/// `<filename>.thumb.jpg` so subsequent renders stay synchronous.
private struct VideoThumbView: View {
    let filePath: String
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black.opacity(0.6)
                    .overlay(ProgressView().controlSize(.small))
            }
            Image(systemName: "play.circle.fill")
                .resizable()
                .frame(width: 44, height: 44)
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 2)
        }
        .task(id: filePath) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let url = URL(fileURLWithPath: filePath)
        let cacheURL = url.deletingPathExtension().appendingPathExtension("thumb.jpg")
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let image = NSImage(byReferencingFile: cacheURL.path) {
            thumbnail = image
            return
        }
        // Run the synchronous frame extraction off the main actor so the
        // chat list does not janck while we wait. `copyCGImage` is available
        // on every supported macOS, and AVAssetImageGenerator is documented
        // thread-safe for read-only use.
        let result: NSImage? = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            var actual = CMTime.zero
            guard let cgImage = try? generator.copyCGImage(
                at: CMTime(seconds: 1.0, preferredTimescale: 600),
                actualTime: &actual
            ) else { return nil }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpegData.write(to: cacheURL)
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
        thumbnail = result
    }
}

/// Compact audio pill — single play/pause button backed by AVAudioPlayer. No
/// scrubber on purpose; voice-notes in the chat list are short and an inline
/// scrubber adds visual noise. Click → Quick Look for full controls.
private struct AudioPlayerPill: View {
    let filePath: String
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(WATheme.Colors.accent)
            }
            .buttonStyle(.plain)

            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
            Text(URL(fileURLWithPath: filePath).lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.08), in: Capsule())
        .frame(maxWidth: 280)
        .onDisappear { player?.stop() }
    }

    private func togglePlayback() {
        if let player {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: filePath))
            p.prepareToPlay()
            p.play()
            player = p
            isPlaying = true
        } catch {
            // Fall back to system handler if AVAudioPlayer can't decode the
            // container (e.g. opus in some containers).
            NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
        }
    }
}

/// File-name chip with a Finder-reveal button for documents.
private struct DocumentChip: View {
    let filePath: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: filePath).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WATheme.Colors.bubbleText)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open")
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 320)
    }
}

private nonisolated(unsafe) let byteCountFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f
}()

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
