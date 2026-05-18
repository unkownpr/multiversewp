# MultiverseWP

> One native macOS app, every WhatsApp account you own — plus an embedded
> MCP server so Claude (and other AI assistants) can read, search, and
> reply for you with your explicit approval.

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue.svg)](#)
[![Built with: Swift 6](https://img.shields.io/badge/swift-6.0-orange.svg)](#)

MultiverseWP is a personal-use, **local-first** desktop client for people who
juggle multiple WhatsApp lines (personal + work + side projects) and want the
calm of a single Apple Mail-style sidebar instead of five Chrome tabs. It
talks to WhatsApp using the same multi-device protocol the official mobile
apps do, via a bundled Go helper based on `whatsmeow` — no scraping, no
browser automation.

The differentiator: an **embedded MCP (Model Context Protocol) server**.
Claude Desktop, Claude Code, or any MCP-compatible AI client can connect and
call typed tools like `search_messages`, `list_chats`, or `send_message`
(the last one always gated by an in-app approval prompt). The app is built
for humans first and AI assistants second.

> Not affiliated with, endorsed by, or sponsored by WhatsApp LLC or Meta
> Platforms. No automation, mass-messaging, or spam capability exists or
> will be added.

---

## Screenshots

Screenshots live in [`docs/screenshots/`](docs/screenshots/). The folder
currently holds only the README that explains the naming convention and
capture workflow — actual marketing screenshots arrive with the first
public release. See [`docs/screenshots/README.md`](docs/screenshots/README.md)
for the refresh procedure.

---

## Features

- **Multi-account.** Run any number of WhatsApp accounts side-by-side. Each
  is an isolated Go subprocess with its own encrypted session.
- **Native macOS.** Pure SwiftUI + AppKit interop. No Catalyst, no Electron.
  Sidebar / chat-list / detail tri-column layout that follows Apple's HIG.
- **Embedded MCP server.** Stdio Model Context Protocol server exposes
  typed tools for AI assistants (read-only by default, writes require an
  explicit human approval per chat or per session).
- **Local-first.** All messages and media live in SQLite (GRDB + FTS5) under
  your Application Support folder. No third-party analytics, telemetry, or
  cloud sync.
- **Dark-mode adaptive.** Honors system appearance automatically — every
  asset (including the app icon) is generated for light, dark, and tinted
  variants.
- **In-app settings.** Per-account notification rules, MCP install helper,
  storage location, auto-update settings (Sparkle, signed feed).
- **Full-text search.** SQLite FTS5 across every message in every account.

---

## Install

### Download

Grab the latest signed DMG from the releases page:

`https://github.com/unkownpr/multiversewp/releases/latest`

*(Replace this URL with the real one once the first release ships.)*

### Drag to Applications

1. Open the DMG.
2. Drag **MultiverseWP.app** into your **Applications** folder.
3. Eject the DMG.

### Gatekeeper workaround for unsigned / pre-release builds

Until the project ships a Developer-ID-signed and Apple-notarized build, the
first launch will trigger:

> *"MultiverseWP.app can't be opened because Apple cannot check it for
> malicious software."*

Workaround:

1. In Finder, **right-click** (or Control-click) `MultiverseWP.app`.
2. Choose **Open**.
3. In the confirmation dialog, click **Open** again.

macOS remembers this choice; double-click works from then on. Notarized
builds will land in Phase 4 and remove this step entirely.

---

## Use with Claude Desktop

MultiverseWP ships an embedded stdio MCP server. The easiest install path is
inside the app — open **Settings → AI / MCP → Install for Claude Desktop**
and it writes the config snippet for you.

If you prefer to wire it by hand, add this block to
`~/Library/Application Support/Claude/claude_desktop_config.json`:

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

Restart Claude Desktop. Tools like `list_accounts`, `list_chats`,
`search_messages`, `get_messages`, `send_message`, and `download_media`
become available. Every write tool prompts MultiverseWP for explicit
approval the first time it is called — there is no silent mode.

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

Cut a local DMG:

```bash
MULTIVERSEWP_VERSION=0.1.0 ./scripts/release.sh
# → release/MultiverseWP-0.1.0.dmg
```

Set `DEVELOPMENT_TEAM`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, and
`NOTARY_TEAM_ID` to ship a notarized build.

Regenerate the app icon set:

```bash
./scripts/make-icon.sh
```

---

## Architecture

| Layer            | Tech                                                  |
| ---------------- | ----------------------------------------------------- |
| UI               | SwiftUI (macOS 14+) with AppKit interop where needed. |
| WhatsApp backend | `whatsmeow` Go helper — one static binary, one process per account, JSON over stdin/stdout. |
| Storage          | SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift), FTS5 for search. |
| Secrets          | macOS Keychain via a small `KeychainStore` wrapper.   |
| MCP              | Stdio Model Context Protocol server, typed tools.     |
| Notifications    | `UserNotifications.framework`, per-account rules.     |
| Auto-update      | [Sparkle 2](https://sparkle-project.org/) with EdDSA-signed feed (Phase 4). |

A short version of the system diagram (full version lives in `CLAUDE.md`):

```
┌──────────────────────────────────────────┐
│         MultiverseWP.app (SwiftUI)        │
│   Features/  Core/  Resources/            │
└────────────────────┬─────────────────────┘
                     │ Unix socket / JSON
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
│   ├── App/               SwiftUI scene + AppEnvironment
│   ├── Core/              Storage, WAClient, Keychain, EventBus, Logging
│   └── Features/          Accounts, Chat, Notifications, MCP
├── Tests/                 XCTest unit suites
├── UITests/               XCTest UI suites
├── Resources/             Assets, entitlements, icon set
├── WhatsmeowHelper/       Go IPC helper
├── agents/                agent role prompts (developer, reviewer, …)
├── docs/                  architecture, patterns, screenshots
└── scripts/               bootstrap, build, test, release, make-icon
```

---

## Roadmap

| Phase | Theme                       | Status     |
| ----- | --------------------------- | ---------- |
| 0     | Foundation (project, shell, helper stub, schema) | done   |
| 1     | Single-account MVP (QR, chat, compose, media)    | in flight |
| 2     | Multi-account (switcher, parallel helpers)       | next      |
| 3     | MCP server + install helper                      | planned   |
| 4     | Notarized DMG, Homebrew cask, OSS launch         | planned   |

The full roadmap with acceptance criteria lives in
[`CLAUDE.md`](CLAUDE.md#roadmap).

---

## License

[MIT](LICENSE). Reserve the right to add additional terms in a future v1.0
release (a `LICENSE-2.0` will sit alongside the existing one if so — the
v0.x line stays MIT-licensed forever).

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
