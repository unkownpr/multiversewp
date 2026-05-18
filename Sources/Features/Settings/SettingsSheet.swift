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

    private var executablePath: String { MCPClientInstaller.currentExecutablePath() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(L10n.t("mcp.title"), systemImage: "brain")
                    .font(.title3.bold())
                Text(L10n.t("mcp.intro"))
                    .foregroundStyle(.secondary)

                GroupBox(L10n.t("mcp.section.status")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 10, height: 10)
                            Text(L10n.t("mcp.status.available"))
                                .font(.callout.weight(.medium))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.t("mcp.executable")).font(.caption).foregroundStyle(.secondary)
                            Text(executablePath)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.primary)
                        }
                        if let message = installMessage {
                            Label(message.text, systemImage: message.systemImage)
                                .font(.caption)
                                .foregroundStyle(message.isError ? Color.red : Color.green)
                        }
                    }
                    .padding(.vertical, 6)
                }

                GroupBox(L10n.t("mcp.section.installers")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(MCPClientTarget.allKnown) { target in
                            installerRow(target: target)
                        }
                    }
                    .padding(.vertical, 6)
                }

                GroupBox(L10n.t("mcp.section.manual")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.t("mcp.manual.intro"))
                            .font(.callout)
                        Text(MCPClientInstaller.snippet())
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        HStack(spacing: 8) {
                            Button {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(MCPClientInstaller.snippet(), forType: .string)
                            } label: {
                                Label(L10n.t("mcp.manual.copy"), systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Text(L10n.t("mcp.manual.help"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .padding(.vertical, 6)
                }

                GroupBox(L10n.t("mcp.section.tools")) {
                    VStack(alignment: .leading, spacing: 6) {
                        bullet(L10n.t("mcp.tool.listAccounts"))
                        bullet(L10n.t("mcp.tool.listChats"))
                        bullet(L10n.t("mcp.tool.getMessages"))
                        bullet(L10n.t("mcp.tool.searchMessages"))
                        bullet(L10n.t("mcp.tool.sendMessage"))
                        bullet(L10n.t("mcp.tool.downloadMedia"))
                    }
                    .padding(.vertical, 6)
                }
                GroupBox(L10n.t("mcp.section.howToUse")) {
                    VStack(alignment: .leading, spacing: 8) {
                        bullet(L10n.t("mcp.howToUse.launch"))
                        bullet(L10n.t("mcp.howToUse.install"))
                        bullet(L10n.t("mcp.howToUse.ask"))
                        bullet(L10n.t("mcp.howToUse.consent"))
                    }
                    .padding(.vertical, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func installerRow(target: MCPClientTarget) -> some View {
        HStack(spacing: 10) {
            Image(systemName: target.symbol)
                .frame(width: 22, alignment: .center)
                .foregroundStyle(WATheme.Colors.accentMid)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.displayName).font(.callout.weight(.medium))
                Text(target.footnote)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(L10n.t("mcp.install.cta")) {
                installEntry(for: target)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func installEntry(for target: MCPClientTarget) {
        let installer = MCPClientInstaller(target: target)
        switch installer.install() {
        case .success(let url):
            installMessage = InstallMessage(
                text: "\(target.displayName): \(L10n.t("mcp.install.success")) \(url.path)",
                systemImage: "checkmark.circle.fill",
                isError: false
            )
        case .failure(let error):
            installMessage = InstallMessage(
                text: "\(target.displayName): \(error.localizedDescription)",
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

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var updater: UpdaterController
    @SwiftUI.AppStorage(L10n.storageKey) private var language: String = L10n.Language.system.rawValue

    @State private var showWelcomeRestored: Bool = false

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
                Button(L10n.t("settings.about.checkUpdates")) {
                    updater.checkForUpdates(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!updater.canCheckForUpdates)
                .padding(.top, 4)
            }
            Text(L10n.t("settings.about.tagline"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            VStack(spacing: 6) {
                Text(L10n.t("settings.about.builtBy"))
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

            languageSection
            welcomeSection

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: NSHomeDirectory())
                            .appendingPathComponent("Library/Application Support/MultiverseWP")
                    )
                } label: {
                    Label(L10n.t("settings.about.dataFolder"), systemImage: "folder")
                }
                Button {
                    if let url = URL(string: "https://github.com/unkownpr/multiversewp") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(L10n.t("settings.about.github"), systemImage: "chevron.left.forwardslash.chevron.right")
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

    private var languageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L10n.t("settings.language.label"), systemImage: "globe")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Picker("", selection: $language) {
                        ForEach(L10n.Language.allCases) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }
                Text(L10n.t("settings.language.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: 420)
    }

    private var welcomeSection: some View {
        VStack(spacing: 6) {
            Button {
                Task {
                    await environment.resetWelcomeTour()
                    showWelcomeRestored = true
                }
            } label: {
                Label(L10n.t("settings.about.resetWelcome"), systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if showWelcomeRestored {
                Text(L10n.t("welcome.reseeded.body"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
