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

    @State private var installMessage: InstallMessage?

    private var executablePath: String { ClaudeDesktopInstaller.currentExecutablePath() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Model Context Protocol", systemImage: "brain")
                    .font(.title3.bold())
                Text("MultiverseWP ships with a local MCP server so AI assistants — Claude Desktop, Claude Code, or any MCP-compatible client — can read your WhatsApp history through a strictly read-only stdio bridge. Sending messages will arrive in a later milestone behind an explicit per-chat approval prompt.")
                    .foregroundStyle(.secondary)

                GroupBox("Status") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 10, height: 10)
                            Text("Available (read-only, run via --mcp flag)")
                                .font(.callout.weight(.medium))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Executable").font(.caption).foregroundStyle(.secondary)
                            Text(executablePath)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.primary)
                        }
                        HStack(spacing: 10) {
                            Button("Install for Claude Desktop") {
                                installClaudeDesktopEntry()
                            }
                            .buttonStyle(.borderedProminent)
                            if let message = installMessage {
                                Label(message.text, systemImage: message.systemImage)
                                    .font(.caption)
                                    .foregroundStyle(message.isError ? Color.red : Color.green)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                GroupBox("Available tools") {
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("list_accounts — list every linked WhatsApp account")
                        bullet("list_chats(account_id?, query?, limit?) — list chats")
                        bullet("get_messages(chat_id, before?, limit?) — fetch history")
                        bullet("search_messages(query, account_id?, chat_id?, limit?) — FTS5 over the local store")
                        bullet("send_message — coming in a later milestone (explicit per-chat approval)")
                        bullet("download_media — coming in a later milestone (explicit per-chat approval)")
                    }
                    .padding(.vertical, 6)
                }
                GroupBox("How you'll use it") {
                    VStack(alignment: .leading, spacing: 8) {
                        bullet("Launch `MultiverseWP --mcp` to attach the stdio MCP server to any AI client.")
                        bullet("Or hit \"Install for Claude Desktop\" above to drop the config entry into `~/Library/Application Support/Claude/claude_desktop_config.json` automatically.")
                        bullet("Then ask your assistant things like \"summarise my unread chats today\" or \"search every conversation for the dentist appointment\".")
                        bullet("Write tools (send_message, download_media) will require per-chat consent prompts when they ship in a later milestone.")
                    }
                    .padding(.vertical, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private func installClaudeDesktopEntry() {
        let installer = ClaudeDesktopInstaller()
        switch installer.install() {
        case .success(let url):
            installMessage = InstallMessage(
                text: "Installed at \(url.path)",
                systemImage: "checkmark.circle.fill",
                isError: false
            )
        case .failure(let error):
            installMessage = InstallMessage(
                text: "Install failed: \(error.localizedDescription)",
                systemImage: "exclamationmark.triangle.fill",
                isError: true
            )
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
        }
    }

    private struct InstallMessage {
        let text: String
        let systemImage: String
        let isError: Bool
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
