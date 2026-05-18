import AppKit
import SwiftUI

struct MessageComposer: View {

    let onSend: (String) async -> Void
    let onSendAttachment: (String, PendingAttachment) async -> Void

    @State private var text: String = ""
    @State private var attachment: PendingAttachment?
    @State private var isSending: Bool = false
    @FocusState private var focused: Bool

    init(
        onSend: @escaping (String) async -> Void,
        onSendAttachment: @escaping (String, PendingAttachment) async -> Void = { _, _ in }
    ) {
        self.onSend = onSend
        self.onSendAttachment = onSendAttachment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachment {
                attachmentChip(attachment)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    focused = true
                    // Surface the standard macOS character / emoji palette. It
                    // inserts into whichever text view is currently the first
                    // responder — which is the composer field a beat after the
                    // focus change above.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Emoji & symbols (⌃⌘Space)")
                .keyboardShortcut(.space, modifiers: [.command, .control])

                Button {
                    attachFile()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach")

                TextField(textFieldPlaceholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(.white, in: Capsule())
                    .overlay(Capsule().stroke(.black.opacity(0.06)))
                    .onSubmit { Task { await send() } }
                    .accessibilityIdentifier("MessageComposerField")

                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var textFieldPlaceholder: String {
        attachment == nil ? L10n.t("composer.placeholder") : L10n.t("composer.caption")
    }

    @ViewBuilder
    private func attachmentChip(_ attachment: PendingAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.symbolName)
                .imageScale(.medium)
                .foregroundStyle(WATheme.Colors.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(attachment.mimeType)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                self.attachment = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
            .accessibilityIdentifier("MessageComposerAttachmentRemove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("MessageComposerAttachmentChip")
    }

    private var sendButton: some View {
        Button {
            Task { await send() }
        } label: {
            ZStack {
                Circle()
                    .fill(canSend ? WATheme.Colors.accent : Color.gray.opacity(0.35))
                    .frame(width: 36, height: 36)
                Image(systemName: canSend ? "paperplane.fill" : "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSend)
        .accessibilityIdentifier("MessageComposerSendButton")
    }

    private var canSend: Bool {
        if isSending { return false }
        if attachment != nil { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        let outgoing = text
        let pending = attachment
        text = ""
        attachment = nil
        isSending = true
        if let pending {
            await onSendAttachment(outgoing, pending)
        } else {
            await onSend(outgoing)
        }
        isSending = false
        focused = true
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            attachment = PendingAttachment(url: url)
        }
    }
}
