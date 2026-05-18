import Foundation
import SwiftUI

/// Lightweight runtime-switchable localization. English (base) + Turkish.
/// Picker lives in Settings → About. Real .lproj-based localization lands
/// in a later pass; this gets a usable bilingual surface today.
public enum L10n {

    public enum Language: String, CaseIterable, Identifiable, Sendable {
        case system
        case english = "en"
        case turkish = "tr"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .system: "System default"
            case .english: "English"
            case .turkish: "Türkçe"
            }
        }
    }

    public static let storageKey = "multiversewp.language"

    public static var current: Language {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? Language.system.rawValue
        return Language(rawValue: raw) ?? .system
    }

    public static var activeCode: String {
        switch current {
        case .english: return "en"
        case .turkish: return "tr"
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            let code = String(preferred.prefix(2)).lowercased()
            return strings[code] == nil ? "en" : code
        }
    }

    public static func t(_ key: String) -> String {
        let code = activeCode
        if let value = strings[code]?[key] { return value }
        if let fallback = strings["en"]?[key] { return fallback }
        return key
    }

    static let strings: [String: [String: String]] = [
        "en": [
            // Settings
            "settings.title": "Settings",
            "settings.done": "Done",
            "settings.tab.accounts": "Accounts",
            "settings.tab.mcp": "AI / MCP",
            "settings.tab.about": "About",
            "settings.about.version": "Version",
            "settings.about.tagline": "A native macOS WhatsApp client that handles multiple accounts and exposes a local MCP server compatible with Claude Desktop, Claude Code, Cursor, and any other MCP-aware AI client. Personal-use project, planned open source.",
            "settings.about.dataFolder": "Data folder",
            "settings.about.github": "GitHub",
            "settings.about.checkUpdates": "Check for Updates Now",
            "settings.about.resetWelcome": "Show welcome tour again",
            "settings.about.builtBy": "Built by Semih Silistre",
            "settings.language.label": "Language",
            "settings.language.help": "Pick which language MultiverseWP shows its menus and labels in. System default follows your macOS Language & Region setting.",

            // MCP tab
            "mcp.title": "Model Context Protocol",
            "mcp.intro": "MultiverseWP ships a local MCP server so AI assistants — Claude Desktop, Claude Code, Cursor, Continue, and any other MCP-compatible client — can read your WhatsApp history through a strictly read-only stdio bridge. Sending messages will require explicit per-chat approval in a later milestone.",
            "mcp.status.available": "Available (read-only, run via --mcp flag)",
            "mcp.executable": "Executable",
            "mcp.install.claude": "Install for Claude Desktop",
            "mcp.install.other": "Other clients: copy the path above into your client's mcpServers config with args [\"--mcp\"].",

            // Account / sidebar
            "account.add": "Add another WhatsApp account",
            "account.settings": "Settings — Accounts, AI/MCP, About",
            "account.status.online": "online",
            "account.status.offline": "offline",
            "account.status.connecting": "connecting…",
            "account.status.awaitingQR": "scan QR to connect",
            "account.status.unauthorized": "re-link required",
            "account.status.welcomeTour": "Welcome tour",
            "account.noAccount": "No account",
            "account.pickAccount": "Pick an account",
            "account.pickAccount.description": "Choose an account from the sidebar.",

            // Chat list
            "chatlist.search": "Search or start new chat",
            "chatlist.empty.title": "No chats yet",
            "chatlist.empty.description": "Conversations will land here once the account is connected.",
            "chatlist.menu.markAllRead": "Mark all as read",
            "chatlist.menu.link": "Link new WhatsApp",
            "chatlist.menu.refreshNews": "Refresh news from GitHub",
            "chatlist.row.placeholder": "Tap to start chatting",

            // Chat detail
            "chat.detail.pick.title": "Pick a chat to start messaging",
            "chat.detail.pick.description": "Your conversations across every connected WhatsApp account live here.",
            "chat.detail.header.group": "Group chat",
            "chat.detail.header.online": "online",
            "chat.detail.actions": "Chat actions — mute / pin / mark unread / reveal media / clear",
            "chat.detail.markUnread": "Mark as unread",
            "chat.detail.mute": "Mute notifications",
            "chat.detail.unmute": "Unmute",
            "chat.detail.pin": "Pin chat",
            "chat.detail.unpin": "Unpin",
            "chat.detail.revealMedia": "Reveal media folder",
            "chat.detail.clearMessages": "Clear messages",

            // Composer
            "composer.placeholder": "Type a message",
            "composer.caption": "Add a caption (optional)",
            "composer.emoji": "Emoji & symbols (⌃⌘Space)",
            "composer.attach": "Attach",
            "composer.removeAttachment": "Remove attachment",

            // Onboarding
            "onboarding.title": "Link a WhatsApp Account",
            "onboarding.help": "On your phone: Settings → Linked Devices → Link a Device",
            "onboarding.preparing": "Preparing helper…",
            "onboarding.pairing": "Linking device…",
            "onboarding.linked": "Linked!",
            "onboarding.tryAgain": "Try Again",
            "onboarding.cancel": "Cancel",
            "onboarding.accountLabel": "Account label",
            "onboarding.refreshes": "Code refreshes automatically.",
            "onboarding.encryption": "End-to-end encryption by WhatsApp",

            // Welcome tour
            "welcome.reseeded.title": "Welcome tour restored",
            "welcome.reseeded.body": "The demo account and its three intro chats are back in the sidebar."
        ],
        "tr": [
            // Settings
            "settings.title": "Ayarlar",
            "settings.done": "Tamam",
            "settings.tab.accounts": "Hesaplar",
            "settings.tab.mcp": "Yapay Zekâ / MCP",
            "settings.tab.about": "Hakkında",
            "settings.about.version": "Sürüm",
            "settings.about.tagline": "Birden fazla WhatsApp hesabını tek pencerede yöneten, Claude Desktop, Claude Code, Cursor ve diğer MCP uyumlu AI istemcilerine açık yerel MCP sunucusu sunan native macOS uygulaması. Kişisel kullanım, ileride açık kaynak.",
            "settings.about.dataFolder": "Veri klasörü",
            "settings.about.github": "GitHub",
            "settings.about.checkUpdates": "Güncellemeleri Şimdi Kontrol Et",
            "settings.about.resetWelcome": "Karşılama turunu tekrar göster",
            "settings.about.builtBy": "Yapımcı: Semih Silistre",
            "settings.language.label": "Dil",
            "settings.language.help": "Menü ve etiketlerin hangi dilde görüneceğini seç. Sistem varsayılanı macOS Dil ve Bölge ayarını izler.",

            // MCP tab
            "mcp.title": "Model Context Protocol",
            "mcp.intro": "MultiverseWP, Claude Desktop, Claude Code, Cursor, Continue ve diğer MCP uyumlu AI istemcilerinin WhatsApp geçmişini salt-okunur bir stdio köprüsünden okuyabilmesi için yerel bir MCP sunucusu çalıştırır. Mesaj göndermek, ileriki bir sürümde sohbet-başına onaylı şekilde gelecek.",
            "mcp.status.available": "Hazır (salt-okunur, --mcp bayrağıyla çalışır)",
            "mcp.executable": "Yürütülebilir yol",
            "mcp.install.claude": "Claude Desktop için Kur",
            "mcp.install.other": "Diğer istemciler: yukarıdaki yolu kendi `mcpServers` yapılandırmanıza `args: [\"--mcp\"]` ile yapıştırın.",

            // Account / sidebar
            "account.add": "Başka bir WhatsApp hesabı ekle",
            "account.settings": "Ayarlar — Hesaplar, AI/MCP, Hakkında",
            "account.status.online": "çevrimiçi",
            "account.status.offline": "çevrimdışı",
            "account.status.connecting": "bağlanıyor…",
            "account.status.awaitingQR": "QR'yi taramak için bekliyor",
            "account.status.unauthorized": "yeniden bağlanmalı",
            "account.status.welcomeTour": "Karşılama turu",
            "account.noAccount": "Hesap yok",
            "account.pickAccount": "Bir hesap seç",
            "account.pickAccount.description": "Sol kenardan bir hesap seç.",

            // Chat list
            "chatlist.search": "Sohbet ara veya başlat",
            "chatlist.empty.title": "Henüz sohbet yok",
            "chatlist.empty.description": "Hesap bağlandığında sohbetler burada görünür.",
            "chatlist.menu.markAllRead": "Hepsini okundu işaretle",
            "chatlist.menu.link": "Yeni WhatsApp bağla",
            "chatlist.menu.refreshNews": "Haberleri GitHub'dan yenile",
            "chatlist.row.placeholder": "Sohbet etmek için dokun",

            // Chat detail
            "chat.detail.pick.title": "Mesajlaşmaya başlamak için bir sohbet seç",
            "chat.detail.pick.description": "Bağlı her WhatsApp hesabının sohbetleri burada görünür.",
            "chat.detail.header.group": "Grup sohbeti",
            "chat.detail.header.online": "çevrimiçi",
            "chat.detail.actions": "Sohbet — sustur / sabitle / okunmadı / medya klasörü / temizle",
            "chat.detail.markUnread": "Okunmadı olarak işaretle",
            "chat.detail.mute": "Bildirimleri sustur",
            "chat.detail.unmute": "Sesi aç",
            "chat.detail.pin": "Sohbeti sabitle",
            "chat.detail.unpin": "Sabitlemeyi kaldır",
            "chat.detail.revealMedia": "Medya klasörünü aç",
            "chat.detail.clearMessages": "Mesajları temizle",

            // Composer
            "composer.placeholder": "Bir mesaj yaz",
            "composer.caption": "Açıklama ekle (isteğe bağlı)",
            "composer.emoji": "Emoji ve semboller (⌃⌘Space)",
            "composer.attach": "Dosya ekle",
            "composer.removeAttachment": "Eki kaldır",

            // Onboarding
            "onboarding.title": "WhatsApp Hesabı Bağla",
            "onboarding.help": "Telefonundan: Ayarlar → Bağlı Cihazlar → Cihaz Bağla",
            "onboarding.preparing": "Yardımcı hazırlanıyor…",
            "onboarding.pairing": "Cihaz bağlanıyor…",
            "onboarding.linked": "Bağlandı!",
            "onboarding.tryAgain": "Tekrar Dene",
            "onboarding.cancel": "İptal",
            "onboarding.accountLabel": "Hesap adı",
            "onboarding.refreshes": "Kod otomatik yenilenir.",
            "onboarding.encryption": "WhatsApp uçtan uca şifreleme",

            // Welcome tour
            "welcome.reseeded.title": "Karşılama turu geri yüklendi",
            "welcome.reseeded.body": "Demo hesap ve üç tanıtım sohbeti yeniden kenar çubuğunda."
        ]
    ]
}

extension Text {
    init(localized key: String) {
        self.init(L10n.t(key))
    }
}
