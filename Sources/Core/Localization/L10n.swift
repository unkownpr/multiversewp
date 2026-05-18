import Foundation
import SwiftUI

/// Lightweight runtime-switchable localization. Two languages for now —
/// English (base) and Turkish — selected via AppStorage so the user can
/// flip between them in Settings without a process restart. Falls back to
/// the system locale ("system") when no explicit choice has been made.
///
/// Real Localizable.strings localization (and the per-locale `.lproj`
/// directories that go with it) lands in a follow-up; this is the smallest
/// thing that gives the user a working picker today.
public enum L10n {

    /// Persisted user choice. `system` follows the macOS-wide locale.
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

    /// Active two-letter code after resolving "system".
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

    /// Look up a translation; falls back to English, then the key itself.
    public static func t(_ key: String) -> String {
        let code = activeCode
        if let value = strings[code]?[key] { return value }
        if let fallback = strings["en"]?[key] { return fallback }
        return key
    }

    /// Bilingual string table. Keep keys short, English-ish, scoped to UI
    /// surface (e.g., "settings.title", "settings.language.label").
    static let strings: [String: [String: String]] = [
        "en": [
            "settings.title": "Settings",
            "settings.done": "Done",
            "settings.tab.accounts": "Accounts",
            "settings.tab.mcp": "AI / MCP",
            "settings.tab.about": "About",
            "settings.about.version": "Version",
            "settings.about.tagline": "A native macOS WhatsApp client that handles multiple accounts and exposes a local MCP server for AI assistants. Personal-use project, planned open source.",
            "settings.about.dataFolder": "Data folder",
            "settings.about.github": "GitHub",
            "settings.about.checkUpdates": "Check for Updates Now",
            "settings.about.resetWelcome": "Show welcome tour again",
            "settings.about.builtBy": "Built by Semih Silistre",
            "settings.language.label": "Language",
            "settings.language.help": "Pick which language MultiverseWP shows its menus and labels in. System default follows your macOS Language & Region setting.",
            "welcome.reseeded.title": "Welcome tour restored",
            "welcome.reseeded.body": "The demo account and its three intro chats are back in the sidebar."
        ],
        "tr": [
            "settings.title": "Ayarlar",
            "settings.done": "Tamam",
            "settings.tab.accounts": "Hesaplar",
            "settings.tab.mcp": "AI / MCP",
            "settings.tab.about": "Hakkında",
            "settings.about.version": "Sürüm",
            "settings.about.tagline": "Birden fazla WhatsApp hesabını tek pencerede yöneten, AI asistanlar için yerel MCP sunucusu açan native macOS uygulaması. Kişisel kullanım, ileride open-source.",
            "settings.about.dataFolder": "Veri klasörü",
            "settings.about.github": "GitHub",
            "settings.about.checkUpdates": "Güncellemeleri Şimdi Kontrol Et",
            "settings.about.resetWelcome": "Karşılama turunu tekrar göster",
            "settings.about.builtBy": "Yapımcı: Semih Silistre",
            "settings.language.label": "Dil",
            "settings.language.help": "Menü ve etiketlerin hangi dilde görüneceğini seç. Sistem varsayılanı macOS Dil ve Bölge ayarını izler.",
            "welcome.reseeded.title": "Karşılama turu geri yüklendi",
            "welcome.reseeded.body": "Demo hesap ve üç tanıtım sohbeti yeniden kenar çubuğunda."
        ]
    ]
}

/// `Text(L10n.t("…"))` shortcut.
extension Text {
    init(localized key: String) {
        self.init(L10n.t(key))
    }
}
