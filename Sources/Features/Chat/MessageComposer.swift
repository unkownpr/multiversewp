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
                attachFile()
            } label: {
                Image(systemName: "paperclip")
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attach file")

            TextField("Write a message", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .onSubmit { Task { await send() } }
                .accessibilityIdentifier("MessageComposerField")

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
            .accessibilityIdentifier("MessageComposerSendButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
