# MultiverseWP — Project Brief

> Bu dosya proje boyunca aktif sistem prompt'udur. Claude Code her oturumda bunu okur.
> Format: COSTAR + Anthropic XML structure. Değişiklikler bu dosyada versiyonlanır.

---

<context>
Proje adı: **MultiverseWP**
Hedef: macOS için native bir WhatsApp client. Tek uygulamadan birden fazla WhatsApp hesabını
yönetebilen, Apple Mail / Things tarzı sidebar-driven, native macOS look-and-feel'e sahip
bir desktop app.

Kullanıcı: bireysel kullanım. Birden fazla WhatsApp hattı (kişisel + iş + diğer) tek bir
uygulamadan yönetmek istiyor. Hedef ileride open-source.

**Kritik diferansiyatör:** Uygulama içinde gömülü bir **MCP (Model Context Protocol) server**
çalışır. Claude Desktop, Claude Code veya diğer MCP-uyumlu AI client'lar bu server'a bağlanıp
sohbet geçmişine bakabilir, kişi listesini sorgulayabilir, mesaj gönderebilir, medya
indirebilir, arama yapabilir. Yani uygulama hem insan hem AI agent için bir WhatsApp
arayüzüdür.

ToS / yasal: bireysel kullanım. WhatsApp resmi API olmadığı için multi-device protocol
üzerinden çalışan whatsmeow library kullanılır. Otomasyon, spam, mass-messaging YOKTUR.
Insan-merkezli kullanım + AI assist.

Teknoloji yığını (kesin):
- **UI:** SwiftUI (macOS 14+), AppKit interop gerektiğinde
- **WhatsApp backend:** whatsmeow (Go) — tek static binary, Swift'ten XPC/Unix socket ile IPC
- **Storage:** SQLite via GRDB.swift, FTS5 ile mesaj arama. Medya `~/Library/Application Support/MultiverseWP/media/<accountID>/`
- **MCP:** stdio MCP server (uygulama --mcp flag ile başlayınca stdio dinler), spec'e tam uyumlu
- **Notifications:** UserNotifications.framework, per-account muting
- **Auth:** WhatsApp Web QR code (whatsmeow yönetir), session encrypted Keychain'de
- **Dağıtım:** notarized .dmg, ileride Homebrew cask + GitHub Releases
</context>

<objective>
Claude Code'un görevi: bu projeyi sıfırdan, modüler ve test edilebilir biçimde inşa etmek.
Her özellik için önce plan, sonra TDD, sonra implementasyon. Asla tek dev commit yapma —
her PR / commit bir konsept (örn: "account onboarding QR flow", "media downloader",
"MCP send_message tool").
</objective>

<style>
- Apple HIG'e uygun macOS native. Catalyst değil, gerçek AppKit/SwiftUI macOS.
- Kod stili: Swift API Design Guidelines + SwiftLint. Async/await öncelikli, callback yok.
- Mimari: feature folders (`Features/Accounts`, `Features/Chat`, `Features/MCP`),
  her feature kendi tests klasörüne sahip.
- Mesajlar arası dependency: protocol-oriented, DI ile inject. Singleton yok.
</style>

<tone>
Mühendis tonu. Kararlar gerekçeli, trade-off açık. Sihirli sayı / magic string yok.
Kullanıcı dokümantasyonu Türkçe + İngilizce, kod yorumları İngilizce.
</tone>

<audience>
Birincil: solo developer (Türkçe konuşur, programc4@gmail.com).
İkincil: ileride open-source contributor'lar — README + ARCHITECTURE.md
contributor-onboarding'ini destekleyecek.
Üçüncül: MCP üzerinden bağlanan AI agent'lar — tool schema'lar self-describing olmalı.
</audience>

<response_format>
Her görev için Claude Code şu çıktıyı vermeli:

1. **Plan** (kısa, madde)
2. **Dosya değişiklikleri** (yeni / değişen / silinen)
3. **Test** (önce yazılan test, sonra geçen test çıktısı)
4. **Risk notları** (eğer varsa: regression, ToS, performance)

Commit mesajı format: Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`).
PR title ≤ 70 chars, açıklama "Why" + "What" + "Test plan".
</response_format>

<constraints>
**ASLA YAPMA:**
- Otomasyon / spam / mass-DM kodu — kullanıcı manuel tetikler her zaman
- WhatsApp credentials veya session token'larını disk'e plaintext yazma → Keychain
- Üçüncü taraf analytics / telemetry — proje %100 local-first
- WhatsApp logo / branding kopyala — kendi ikonografi
- Single-file mega-modül — feature'lar izole
- UIKit / Catalyst yaklaşımı — sadece native macOS SwiftUI/AppKit
- Force-unwrap (`!`) production kodunda — tests istisna
- Hardcoded path — `FileManager.default.urls(for:in:)` kullan

**HER ZAMAN YAP:**
- MCP tool eklendiğinde önce tool schema (JSON Schema) yaz, sonra Swift handler
- Yeni özellikten önce: `references/` veya context7 ile ilgili lib doc oku
- whatsmeow Go helper'ı release-built static binary olarak bundle et,
  development'ta `WHATSMEOW_BIN` env override desteği bırak
- Her DB değişikliği migration ile — schema versioning zorunlu
- Hassas log: telefon numaraları, mesaj içeriği DEBUG dışında loglanmaz
</constraints>

<architecture>
## Üst seviye bileşenler

```
┌─────────────────────────────────────────────────┐
│            MultiverseWP.app (SwiftUI)           │
│  ┌──────────────────────────────────────────┐   │
│  │  Features/                                │   │
│  │   ├── Accounts (QR onboarding, switcher) │   │
│  │   ├── Chat (message list, composer)      │   │
│  │   ├── Contacts (sync, search)            │   │
│  │   ├── Media (attach, preview, download)  │   │
│  │   ├── Notifications (per-account rules)  │   │
│  │   └── MCP (stdio server + tool registry) │   │
│  └──────────────────────────────────────────┘   │
│                      │                            │
│              Core/ (shared)                       │
│   ├── WAClient (Swift wrapper over whatsmeow IPC)│
│   ├── Storage (GRDB + FTS5)                      │
│   ├── KeychainStore                              │
│   └── EventBus (Combine publishers)              │
└──────────────────┬──────────────────────────────┘
                   │ Unix socket / XPC
                   ▼
┌─────────────────────────────────────────────────┐
│   whatsmeow-helper (Go static binary)            │
│   - Bir process per account                      │
│   - Protobuf event stream → Swift              │
│   - Commands: connect, send, fetch_history, …   │
└─────────────────────────────────────────────────┘
```

## MCP Tools (minimum v1 set)

- `list_accounts` — bağlı hesapları döner
- `list_chats(account_id, limit, query?)` — sohbetleri listeler
- `get_messages(chat_id, before?, limit)` — sohbet geçmişi
- `search_messages(query, account_id?, chat_id?)` — FTS5 arama
- `send_message(chat_id, text, attachments?)` — mesaj gönder (kullanıcı onayı UI prompt'u zorunlu)
- `list_contacts(account_id, query?)` — kişi arama
- `get_contact(jid)` — kişi detayı + son mesaj
- `download_media(message_id)` — medya indir, path döner

**Onay modeli:** `send_message` ve `download_media` ilk çağrıda kullanıcı UI'da onay verir,
isterse "auto-approve for this chat / 1h" seçenekleri.
</architecture>

<roadmap>
**Phase 0 — Foundation** (1. milestone)
- Xcode project, SwiftUI shell, SwiftLint, GitHub Actions CI
- whatsmeow helper minimal: connect + QR + receive message event
- GRDB schema v1: accounts, chats, messages, contacts, media
- Keychain wrapper

**Phase 1 — Single account MVP**
- QR onboarding flow
- Chat list + message view (read-only ilk)
- Compose + send text
- Native notifications
- Media: attach + receive image/video/file

**Phase 2 — Multi-account**
- Account switcher sidebar
- Parallel helper processes
- Per-account notification rules
- Unified search across accounts

**Phase 3 — MCP**
- Stdio MCP server skeleton
- Read-only tools (list_*, get_*, search_messages)
- Write tools with approval UI (send_message, download_media)
- MCP install helper: `multiversewp --install-mcp claude-desktop`

**Phase 4 — Polish + OSS release**
- ARCHITECTURE.md, CONTRIBUTING.md
- Notarization + DMG build
- Homebrew cask
- Demo video
</roadmap>

<examples>
<example name="iyi-task-cevabı">
Kullanıcı: "QR onboarding ekranını ekle"

Claude Code çıktısı:
1. Plan:
   - `Features/Accounts/QRCodeView.swift` — SwiftUI view, QR string → CIImage
   - `Features/Accounts/OnboardingViewModel.swift` — whatsmeow event stream'i dinler
   - Test: `OnboardingViewModelTests.swift` — mock WAClient ile QR refresh ve pair-success
2. Dosya değişiklikleri: (+3 yeni, +0 değişen)
3. Test çıktısı: `swift test --filter Onboarding` → 4 passed
4. Risk: QR string 60s TTL — refresh logic E2E test edilemiyor (manual smoke gerekir)
</example>

<example name="kötü-task-cevabı">
Kullanıcı: "QR onboarding ekranını ekle"

Claude Code çıktısı: 800 satır tek commit, test yok, hem QR hem multi-account hem MCP
tool eklenmiş. ❌ Kapsam dışı, atomik değil, gözden geçirilemez.
</example>
</examples>

---

## ÖNEMLİ HATIRLATMA (recency için sona)

- **Asla otomasyon-spam pattern yazma.** Her dış aksiyon kullanıcı veya MCP-onaylı.
- **whatsmeow binary'sini Swift'ten çağırırken** her zaman sandbox-safe path + structured
  protobuf message kullan, string parsing yok.
- **MCP tool yazarken** önce JSON Schema, sonra handler. Schema self-describing olmalı
  ki AI agent örnek görmeden kullanabilsin.
- **Test yoksa merge yok.** UI testleri için Xcode UI test, logic için Swift Testing.
- **Türkçe yorum yazma kodda, README'ye yaz.** Kod İngilizce, dokümantasyon iki dilli.
- **Token / secret loglanırsa bug.** Logger'da redaction wrapper kullan.

---

## Self-Improving Loop

Her özellik bittikten sonra Claude Code şunu yapsın:
1. **Critique:** "Bu modülün en zayıf yönü? Hangi edge case açık?"
2. **Challenge:** "Bu mimari kararın en güçlü karşı argümanı ne?"
3. **Refine:** eksikler için issue aç, follow-up PR planla.
4. **Pattern kaydet:** başarılı pattern → `docs/patterns/<topic>.md`
