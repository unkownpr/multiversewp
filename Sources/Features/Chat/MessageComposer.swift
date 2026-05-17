import AppKit
import SwiftUI

struct MessageComposer: View {

    let onSend: (String) async -> Void

    @State private var text: String = ""
    @State private var isSending: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                // emoji picker not wired yet
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Emoji")
            .disabled(true)

            Button {
                attachFile()
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach")

            TextField("Type a message", text: $text, axis: .vertical)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func send() async {
        let outgoing = text
        text = ""
        isSending = true
        await onSend(outgoing)
        isSending = false
        focused = true
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            text += "\n[attached: \(url.lastPathComponent)]"
        }
    }
}
