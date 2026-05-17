import AppKit
import SwiftUI

struct SettingsSheet: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Tab = .accounts

    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case accounts
        case mcp
        case about
        var id: String { rawValue }

        var label: String {
            switch self {
            case .accounts: "Accounts"
            case .mcp: "AI / MCP"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .accounts: "person.crop.circle"
            case .mcp: "brain"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(Tab.allCases) { tab in
                        Label(tab.label, systemImage: tab.symbol)
                            .tag(tab)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 180)

                Divider()

                Group {
                    switch selection {
                    case .accounts: AccountsTab()
                    case .mcp: MCPTab()
                    case .about: AboutTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

private struct AccountsTab: View {

    @EnvironmentObject private var environment: AppEnvironment
    @State private var renameTarget: Account?
    @State private var renameDraft: String = ""
    @State private var deleteTarget: Account?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if environment.accounts.isEmpty {
                ContentUnavailableView(
                    "No accounts linked",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Use ⌘⇧N or the sidebar plus button to link your first WhatsApp account.")
                )
            } else {
                List {
                    ForEach(environment.accounts) { account in
                        row(for: account)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .sheet(item: $renameTarget) { account in
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename Account").font(.headline)
                Text("Choose a label that helps you tell this account apart from others.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Account label", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { renameTarget = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task {
                            await environment.renameAccount(account.id, to: trimmed)
                            renameTarget = nil
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(minWidth: 360)
        }
        .alert(
            "Remove this account?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { account in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Remove", role: .destructive) {
                Task {
                    await environment.removeAccount(account.id)
                    deleteTarget = nil
                }
            }
        } message: { account in
            Text("\"\(account.displayName)\" will be removed along with its local chat history. WhatsApp on your phone will keep the device pairing; unlink it from Settings → Linked Devices when you no longer need it.")
        }
    }

    @ViewBuilder
    private func row(for account: Account) -> some View {
        HStack(spacing: 12) {
            AvatarView(seed: account.id.uuidString, label: account.displayName, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body)
                Text(stateLabel(account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename") {
                renameDraft = account.displayName
                renameTarget = account
            }
            .buttonStyle(.bordered)
            Button("Remove", role: .destructive) {
                deleteTarget = account
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func stateLabel(_ account: Account) -> String {
        switch account.connectionState {
        case .connected: "Online" + (account.jid.map { " · \($0)" } ?? "")
        case .connecting: "Connecting…"
        case .awaitingQR: "Awaiting QR scan"
        case .unauthorized: "Re-link required"
        case .disconnected: "Offline"
        }
    }
}

private struct MCPTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Model Context Protocol", systemImage: "brain")
                    .font(.title3.bold())
                Text("MultiverseWP will expose its chat history, contacts, and send-message capability through a local MCP server so AI assistants — Claude Desktop, Claude Code, or any MCP-compatible client — can reach into your conversations with your explicit approval.")
                    .foregroundStyle(.secondary)
                GroupBox("Planned tools") {
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("list_accounts — list every linked WhatsApp account")
                        bullet("list_chats(account_id, query?) — list chats for one account")
                        bullet("get_messages(chat_id, before?, limit) — fetch history")
                        bullet("search_messages(query, scope?) — FTS5 over the local store")
                        bullet("send_message(chat_id, text, attachments?) — explicit user approval prompt")
                        bullet("list_contacts(account_id, query?) — contact lookup")
                        bullet("download_media(message_id) — local file path back to the client")
                    }
                    .padding(.vertical, 6)
                }
                GroupBox("Status") {
                    HStack(spacing: 10) {
                        Image(systemName: "hammer.fill").foregroundStyle(.orange)
                        Text("Phase 3 — not implemented yet. The server skeleton lands in the next milestone; the tool schemas above are frozen.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                GroupBox("How you'll use it") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Once Phase 3 ships:").font(.callout.weight(.medium))
                        bullet("Launch `MultiverseWP --mcp` to attach the stdio MCP server to any AI client.")
                        bullet("Or hit \"Install for Claude Desktop\" here and the config entry lands in `~/Library/Application Support/Claude/claude_desktop_config.json` automatically.")
                        bullet("Then ask your assistant things like \"summarise my unread chats today\", \"draft a reply in the family group\", or \"search every conversation for the dentist appointment\".")
                        bullet("Each write action triggers a per-chat consent prompt the first time; you can grant auto-approve for 1 hour per chat.")
                    }
                    .padding(.vertical, 6)
                }
                GroupBox("Configurable here later") {
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("Toggle the stdio MCP server on / off")
                        bullet("Auto-install Claude Desktop config")
                        bullet("Manage per-chat auto-approval list")
                        bullet("View live MCP traffic / last 50 tool calls")
                    }
                    .padding(.vertical, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
        }
    }
}

private struct AboutTab: View {

    private var version: String {
        let dict = Bundle.main.infoDictionary
        let short = dict?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = dict?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(WATheme.Colors.accent)
                    .frame(width: 96, height: 96)
                Image(systemName: "infinity")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 4) {
                Text("MultiverseWP").font(.title2.bold())
                Text("Version \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("A native macOS WhatsApp client that handles multiple accounts and exposes a local MCP server for AI assistants. Personal-use project, planned open source.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            VStack(spacing: 6) {
                Text("Built by Semih Silistre")
                    .font(.callout)
                if let url = URL(string: "https://ssilistre.dev") {
                    Link(destination: url) {
                        Label("ssilistre.dev", systemImage: "globe")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WATheme.Colors.accentMid)
                }
            }

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: NSHomeDirectory())
                            .appendingPathComponent("Library/Application Support/MultiverseWP")
                    )
                } label: {
                    Label("Data folder", systemImage: "folder")
                }
                Button {
                    if let url = URL(string: "https://github.com/semihsilistre/multiversewp") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            Spacer()
            Text("© 2026 Semih Silistre · ssilistre.dev")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
