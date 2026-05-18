# MultiverseWP

> One native macOS app, every WhatsApp account you own — plus an embedded
> MCP server so Claude (and other AI assistants) can read, search, and
> reply for you.

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue.svg)](#)
[![Built with: Swift 6](https://img.shields.io/badge/swift-6.0-orange.svg)](#)
[![Notarized](https://img.shields.io/badge/distribution-Notarized%20Developer%20ID-success)](#install)

MultiverseWP is a personal-use, **local-first** desktop client for people who
juggle multiple WhatsApp lines (personal + work + side projects) and want the
calm of a single Apple Mail-style sidebar instead of five Chrome tabs. It
speaks the WhatsApp multi-device protocol through a bundled Go helper built
on `whatsmeow` — no scraping, no browser automation.

The differentiator: an **embedded MCP (Model Context Protocol) server**.
Claude Desktop, Claude Code, Cursor, Continue, or any MCP-compatible AI
client can connect and call typed tools (read history, search, send
messages, create groups, look up phone numbers, fetch group members,
download media on demand).

> Not affiliated with, endorsed by, or sponsored by WhatsApp LLC or Meta
> Platforms. No automation, mass-messaging, or spam capability exists or
> will be added.

---

## Features

- **Multi-account.** Run any number of WhatsApp accounts side-by-side. Each
  is an isolated Go subprocess with its own encrypted session.
- **Native macOS 14+.** Pure SwiftUI + AppKit interop. No Catalyst, no
  Electron. Sidebar / chat-list / detail tri-column layout that follows
  Apple HIG.
- **Embedded MCP server.** Stdio Model Context Protocol server exposes
  10 typed tools (`list_accounts`, `list_chats`, `get_messages`,
  `get_messages_with_contact`, `search_messages`, `download_media_now`,
  `send_message`, `list_group_members`, `create_group`, `check_phone`).
- **One-click MCP install** for Claude Desktop, Claude Code, Cursor, and
  Continue from inside Settings → AI / MCP. Manual JSON snippet provided
  for every other MCP-aware client.
- **Menu-bar item + Dock badge.** Total unread count surfaces in both
  surfaces, so new messages stay visible even with the window closed. The
  process stays alive after the last window closes so banners keep
  arriving; click the menu-bar icon to bring a window back.
- **Native notifications.** `UNUserNotificationCenter` banners + sound
  when a message arrives, with a Settings → Notifications tab to verify
  permission, jump to System Settings, and fire a test banner.
- **Bilingual.** Full TR / EN UI, runtime-switchable. The selection is
  persisted (`@AppStorage("multiversewp.language")`).
- **Reply previews, group titles, emoji / sticker / GIF fallbacks** in
  every bubble.
- **Local-first storage.** SQLite (GRDB + FTS5) under your Application
  Support folder. No third-party analytics, telemetry, or cloud sync.
- **Auto-updates.** Sparkle 2.x with an EdDSA-signed appcast served from
  GitHub Pages. Updates are notarized before they reach the user.
- **Dark-mode adaptive.** Honors system appearance — every asset, icon
  variant included.
- **Full-text search.** FTS5 across every message in every account.

---

## Install

Grab the latest DMG from
**<https://github.com/unkownpr/multiversewp/releases/latest>**.

Releases are **signed with a Developer ID Application certificate and
notarized by Apple**. Gatekeeper opens them on first launch without the
right-click workaround.

1. Open the DMG.
2. Drag **MultiverseWP.app** into your **Applications** folder.
3. Eject the DMG and launch the app.

> Use Finder's drag — **do not** copy with `cp -R` from the command line.
> The bundle contains a versioned `Sparkle.framework` whose symlinks
> survive `ditto` / Finder but break under plain `cp -R`, leaving the
> codesign chain invalid.

---

## Use with an MCP client

MultiverseWP ships a stdio MCP server. The easiest install path is
**Settings → AI / MCP → Install for …** — pick the target client and the
app merges the config snippet idempotently.

Supported one-click installers:

- Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`)
- Claude Code (`~/Library/Application Support/ClaudeCode/mcp.json`)
- Cursor (`~/.cursor/mcp.json`)
- Continue (`~/.continue/config.json`)

If you prefer to wire it by hand, copy the snippet the Settings tab shows
and paste it into your client's MCP config. The minimum payload:

```jsonc
{
  "mcpServers": {
    "multiversewp": {
      "command": "/Applications/MultiverseWP.app/Contents/MacOS/MultiverseWP",
      "args": ["--mcp"]
    }
  }
}
```

Restart the MCP client. The 10 tools listed above become available.
Write tools (`send_message`, `create_group`) execute directly — this
build targets a single trusted user; per-call approval prompts are a
future-phase opt-in.

---

## Build from source

```bash
# Once on a fresh checkout — installs missing tools (xcodegen, swiftlint,
# go, protobuf) via Homebrew and produces a working Xcode project plus
# the whatsmeow helper binary.
./scripts/bootstrap.sh

# Open and run:
open MultiverseWP.xcodeproj
```

Cut a local DMG (ad-hoc signed, opens on your Mac only):

```bash
MULTIVERSEWP_VERSION=0.1.0 ./scripts/release.sh
# → release/MultiverseWP-0.1.0.dmg
```

Cut a notarized DMG that opens on any Mac:

```bash
# Pre-flight: store notarytool creds in the Keychain once.
xcrun notarytool store-credentials multiversewp-notary \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"

DEVELOPMENT_TEAM=YOURTEAMID \
MULTIVERSEWP_VERSION=0.1.0 \
  ./scripts/release.sh
```

The script auto-detects the `Developer ID Application: …` identity from
your Keychain, signs every nested Mach-O (helper, frameworks, XPC
services) with `--options runtime --timestamp`, submits the app and the
DMG to Apple's notary service, staples both, and emits an EdDSA-signed
`appcast.xml` for Sparkle.

Regenerate the app icon set:

```bash
./scripts/make-icon.sh
```

---

## Architecture

| Layer            | Tech                                                  |
| ---------------- | ----------------------------------------------------- |
| UI               | SwiftUI (macOS 14+) with AppKit interop where needed. |
| WhatsApp backend | `whatsmeow` Go helper — one static binary, one process per account, length-prefixed JSON over stdin/stdout. |
| Storage          | SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift), FTS5 for search, versioned migrations. |
| Secrets          | macOS Keychain via `KeychainStore` wrapper.           |
| MCP              | Stdio Model Context Protocol server, 10 typed tools.  |
| Notifications    | `UserNotifications.framework` with foreground delegate so banners surface while the app is active. |
| Menu bar / Dock  | `NSStatusItem` + `NSApp.dockTile.badgeLabel`, both driven by an `AppEnvironment.@Published totalUnread`. |
| Auto-update      | [Sparkle 2](https://sparkle-project.org/) with EdDSA-signed feed published to GitHub Pages by `release.sh`. |

System diagram:

```
┌──────────────────────────────────────────┐
│         MultiverseWP.app (SwiftUI)        │
│   Features/  Core/  Resources/            │
└────────────────────┬─────────────────────┘
                     │ Length-prefixed JSON
                     ▼
┌──────────────────────────────────────────┐
│  whatsmeow-helper (Go, one per account)   │
└──────────────────────────────────────────┘
```

---

## Repo layout

```
multiversewp/
├── CLAUDE.md              project brief (source of truth)
├── README.md              this file
├── LICENSE                MIT
├── CONTRIBUTING.md        branch / commit / test conventions
├── project.yml            XcodeGen spec
├── Sources/               Swift source code
│   ├── App/               @main, AppDelegate, MenuBarController, AppEnvironment
│   ├── Core/              Storage, WAClient, Keychain, EventBus, Localization
│   └── Features/          Accounts, Chat, Notifications, MCP, Settings, Updates
├── Tests/                 XCTest unit suites
├── UITests/               XCTest UI suites
├── Resources/             Assets, entitlements, icon set, Info.plist
├── WhatsmeowHelper/       Go IPC helper (whatsmeow + protobuf)
├── agents/                agent role prompts (developer, reviewer, …)
├── docs/                  architecture, patterns, screenshots
└── scripts/               bootstrap, build, test, release, make-icon
```

---

## Roadmap

| Phase | Theme                                          | Status |
| ----- | ---------------------------------------------- | ------ |
| 0     | Foundation (project, shell, helper, schema)    | done   |
| 1     | Single-account MVP (QR, chat, compose, media)  | done   |
| 2     | Multi-account (switcher, parallel helpers)     | done   |
| 3     | MCP server + multi-client install helper       | done   |
| 4     | Notarized DMG + Sparkle appcast + GitHub Pages | done   |
| 5     | Homebrew cask + public OSS launch              | next   |

The full roadmap with acceptance criteria lives in
[`CLAUDE.md`](CLAUDE.md#roadmap).

---

## License

[MIT](LICENSE). The v0.x line stays MIT-licensed forever; v1.0 may add a
secondary license file (`LICENSE-2.0`) but never retroactively replaces
the existing one.

---

## Credits

Built by **Semih Silistre** — <https://ssilistre.dev>.

Stands on the shoulders of:

- [whatsmeow](https://github.com/tulir/whatsmeow) — the Go library that
  speaks the WhatsApp multi-device protocol.
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite for Swift.
- [Sparkle](https://sparkle-project.org/) — auto-updates done right.
- [Model Context Protocol](https://modelcontextprotocol.io/) — the open
  standard the embedded server speaks.
