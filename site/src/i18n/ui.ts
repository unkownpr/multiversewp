export const languages = {
  tr: 'TR',
  en: 'EN',
} as const;

export const defaultLang = 'tr' as const;

export type Lang = keyof typeof languages;

export const ui = {
  tr: {
    'nav.features': 'Özellikler',
    'nav.mcp': 'MCP',
    'nav.download': 'İndir',
    'nav.github': 'GitHub',

    'hero.tag': 'macOS · Native · Local-first',
    'hero.title': 'Tek pencerede tüm WhatsApp hesapların.',
    'hero.subtitle': 'MultiverseWP, birden fazla WhatsApp hattını Apple Mail rahatlığında yöneten native bir macOS uygulamasıdır. Yanına gömülü bir MCP server geliyor — Claude (ve diğer AI asistanlar) sohbetlerini okuyabilir, arayabilir, senin adına cevap yazabilir.',
    'hero.cta.download': 'DMG indir',
    'hero.cta.github': 'GitHub\'da gör',
    'hero.note': 'macOS 14+ · Apple Silicon · Notarized · MIT',

    'features.heading': 'Neler var',
    'features.sub': 'Native uygulama, sıfır Electron, sıfır WebView. Tamamı SwiftUI + AppKit.',

    'f.multi.t': 'Çoklu hesap',
    'f.multi.d': 'Sınırsız WhatsApp hattını yan yana çalıştır. Her hesap kendi izole Go process\'i + şifrelenmiş session.',

    'f.mcp.t': 'Gömülü MCP server',
    'f.mcp.d': 'Stdio Model Context Protocol server. Claude Desktop, Claude Code, Cursor, Continue — tek tıkla bağlanır.',

    'f.local.t': 'Local-first depolama',
    'f.local.d': 'SQLite (GRDB + FTS5) ile Application Support altında. Telemetri yok, üçüncü taraf yok, bulut yok.',

    'f.menubar.t': 'Menü çubuğu + Dock rozeti',
    'f.menubar.d': 'Toplam okunmamış mesaj sayısı her iki yerde de görünür. Pencere kapalıyken bile bildirim gelir.',

    'f.notify.t': 'Native bildirim',
    'f.notify.d': 'UNUserNotificationCenter banner + ses. Ayarlardan izin doğrulama ve test banner\'ı.',

    'f.bilingual.t': 'TR / EN UI',
    'f.bilingual.d': 'Çalışma zamanı dil değişimi, @AppStorage ile persist. Tüm metinler iki dilde.',

    'f.presence.t': 'Canlı durum',
    'f.presence.d': 'Tekli sohbetlerde yazıyor / ses kaydediyor / çevrimiçi / son görülme — whatsmeow Presence event\'leri ile.',

    'f.search.t': 'Tam metin arama',
    'f.search.d': 'FTS5 üzerinden her hesaptaki her mesajda arama. Türkçe + İngilizce indeks.',

    'f.update.t': 'Otomatik güncelleme',
    'f.update.d': 'Sparkle 2.x + EdDSA imzalı appcast. Her sürüm Apple tarafından notarize edilmiş.',

    'mcp.heading': 'AI asistanın için bir WhatsApp arayüzü',
    'mcp.sub': 'MultiverseWP, Model Context Protocol üzerinden 10 typed tool sunar. Claude konuşmalarını okur, arar, yanıt taslakları üretir — hepsi cihazından çıkmadan.',
    'mcp.tool.list_accounts': 'Bağlı hesapları listele',
    'mcp.tool.list_chats': 'Sohbetleri getir',
    'mcp.tool.get_messages': 'Mesaj geçmişi',
    'mcp.tool.search_messages': 'FTS5 arama',
    'mcp.tool.send_message': 'Mesaj gönder (onaylı)',
    'mcp.tool.download_media': 'Medya indir (onaylı)',
    'mcp.tool.list_group_members': 'Grup üyeleri',
    'mcp.tool.create_group': 'Grup oluştur',
    'mcp.tool.check_phone': 'Numara WhatsApp\'ta mı?',
    'mcp.tool.list_contacts': 'Kişileri listele',

    'mcp.install.heading': 'Tek tık MCP kurulumu',
    'mcp.install.sub': 'Settings → AI / MCP sekmesinden Claude Desktop, Claude Code, Cursor veya Continue için tek tıkla kur. Diğer client\'lar için kopyalanabilir JSON snippet.',

    'download.heading': 'İndir',
    'download.sub': 'Apple Notarized DMG. Gatekeeper ilk açılışta sorunsuz açar.',
    'download.cta': 'En son sürümü indir',
    'download.req': 'macOS 14+ · Apple Silicon veya Intel · ~25 MB',

    'footer.legal': 'WhatsApp LLC veya Meta Platforms ile bağlantılı değildir, onaylı değildir, sponsorlu değildir. Otomasyon, toplu mesaj veya spam yeteneği yoktur.',
    'footer.made': 'Semih Silistre tarafından geliştirildi · MIT lisans · 2026',
    'footer.privacy': 'Gizlilik: hiçbir veri cihazından çıkmaz. Üçüncü taraf analitik yok.',
  },
  en: {
    'nav.features': 'Features',
    'nav.mcp': 'MCP',
    'nav.download': 'Download',
    'nav.github': 'GitHub',

    'hero.tag': 'macOS · Native · Local-first',
    'hero.title': 'Every WhatsApp account in one window.',
    'hero.subtitle': 'MultiverseWP is a native macOS client for people who juggle multiple WhatsApp lines. It ships with an embedded MCP server — so Claude (and other AI assistants) can read, search, and reply to your chats with your approval.',
    'hero.cta.download': 'Download DMG',
    'hero.cta.github': 'View on GitHub',
    'hero.note': 'macOS 14+ · Apple Silicon · Notarized · MIT',

    'features.heading': 'What you get',
    'features.sub': 'Native app. Zero Electron. Zero WebView. Pure SwiftUI + AppKit.',

    'f.multi.t': 'Multi-account',
    'f.multi.d': 'Run any number of WhatsApp lines side by side. Each is an isolated Go subprocess with its own encrypted session.',

    'f.mcp.t': 'Embedded MCP server',
    'f.mcp.d': 'Stdio Model Context Protocol server. Claude Desktop, Claude Code, Cursor, Continue — one-click connect.',

    'f.local.t': 'Local-first storage',
    'f.local.d': 'SQLite (GRDB + FTS5) under your Application Support. No telemetry, no third-party SDKs, no cloud sync.',

    'f.menubar.t': 'Menu-bar + Dock badge',
    'f.menubar.d': 'Total unread surfaces in both spots. Banners keep arriving even when the window is closed.',

    'f.notify.t': 'Native notifications',
    'f.notify.d': 'UNUserNotificationCenter banners + sound. Settings tab verifies permission and fires a test banner.',

    'f.bilingual.t': 'TR / EN UI',
    'f.bilingual.d': 'Runtime language switch, persisted with @AppStorage. Every string is bilingual.',

    'f.presence.t': 'Live presence',
    'f.presence.d': 'Typing / recording / online / last-seen in solo chats — wired through whatsmeow Presence events.',

    'f.search.t': 'Full-text search',
    'f.search.d': 'FTS5 across every message in every account. Bilingual index.',

    'f.update.t': 'Auto-update',
    'f.update.d': 'Sparkle 2.x with an EdDSA-signed appcast. Every release is notarized by Apple before reaching you.',

    'mcp.heading': 'A WhatsApp surface for your AI assistant',
    'mcp.sub': 'MultiverseWP exposes 10 typed tools over the Model Context Protocol. Claude reads, searches, and drafts replies — without your data ever leaving the device.',
    'mcp.tool.list_accounts': 'List connected accounts',
    'mcp.tool.list_chats': 'List chats',
    'mcp.tool.get_messages': 'Message history',
    'mcp.tool.search_messages': 'FTS5 search',
    'mcp.tool.send_message': 'Send message (approved)',
    'mcp.tool.download_media': 'Download media (approved)',
    'mcp.tool.list_group_members': 'Group members',
    'mcp.tool.create_group': 'Create group',
    'mcp.tool.check_phone': 'Is number on WhatsApp?',
    'mcp.tool.list_contacts': 'List contacts',

    'mcp.install.heading': 'One-click MCP install',
    'mcp.install.sub': 'Settings → AI / MCP installs into Claude Desktop, Claude Code, Cursor, or Continue with one click. Copyable JSON snippet for every other MCP-aware client.',

    'download.heading': 'Download',
    'download.sub': 'Apple notarized DMG. Gatekeeper opens it on first launch — no right-click workaround.',
    'download.cta': 'Download latest release',
    'download.req': 'macOS 14+ · Apple Silicon or Intel · ~25 MB',

    'footer.legal': 'Not affiliated with, endorsed by, or sponsored by WhatsApp LLC or Meta Platforms. No automation, mass-messaging, or spam capability exists or will be added.',
    'footer.made': 'Built by Semih Silistre · MIT license · 2026',
    'footer.privacy': 'Privacy: nothing leaves your device. No third-party analytics.',
  },
} as const;

export type Key = keyof typeof ui['tr'];
