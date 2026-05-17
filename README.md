# MultiverseWP

A native macOS WhatsApp client that lets one app handle multiple WhatsApp
accounts side-by-side, with an embedded MCP (Model Context Protocol) server so
AI assistants can read history, search messages, and send replies with explicit
user approval.

> Personal-use project. Spam, mass-messaging, or any automation against another
> party's consent are out of scope and will never be implemented. See
> `CLAUDE.md` for the full constraint list.

## Status

Phase 0 — Foundation: in flight (Xcode project, GRDB schema, whatsmeow helper
stub, sidebar shell). Phase 1 — single-account MVP: also in flight (QR
onboarding, chat list & detail, composer).

Phase 2 (multi-account), Phase 3 (MCP), Phase 4 (OSS polish + notarized DMG)
are tracked in `CLAUDE.md`.

## Quick Start

```bash
# Once: install toolchain
brew install xcodegen swiftlint go protobuf

# Generate the Xcode project, build the helper stub
./scripts/bootstrap.sh

# Open Xcode and run the MultiverseWP scheme
open MultiverseWP.xcodeproj
```

The app launches with an onboarding sheet that renders a stub QR (the helper
is in simulation mode). Once the upstream `whatsmeow` Go dependency is wired
in, the same flow will pair real WhatsApp devices.

## Repo Layout

```
multiversewp/
├── CLAUDE.md                    project brief (single source of truth)
├── project.yml                  XcodeGen spec
├── Sources/                     Swift source code
│   ├── App/                     SwiftUI scene + AppEnvironment
│   ├── Core/                    Storage, WAClient, Keychain, EventBus, Logging
│   └── Features/                Accounts, Chat, Notifications, MCP (later phases)
├── Tests/                       XCTest unit suites
├── UITests/                     XCTest UI suites
├── Resources/                   Assets + entitlements
├── WhatsmeowHelper/             Go IPC helper (one process per account)
├── agents/                      role prompts (developer / reviewer / tester / po)
├── docs/                        architecture + pattern notes
└── scripts/                     bootstrap, build, test
```

## Architecture

A short version (full architecture diagram in `CLAUDE.md`):

- SwiftUI macOS app with a sidebar / chat-list / detail tri-column layout.
- One Go subprocess per WhatsApp account, talking newline-delimited JSON
  over stdin/stdout.
- GRDB (SQLite) for persistence; FTS5 for full-text message search.
- Keychain for session metadata.
- MCP server (Phase 3) exposes typed tools: `list_accounts`, `list_chats`,
  `search_messages`, `send_message`, etc.

## Development Workflow

The project is built by a small team of LLM-driven agents (see `agents/`):

- **Developer** writes a single concept per dispatch.
- **Reviewer** audits the diff.
- **Tester** runs the suite and reports.
- **Product Owner** maps user intent to acceptance criteria.

The orchestrator (main Claude Code session) sequences these for each story.

## Testing

```bash
./scripts/test.sh
```

Runs `xcodebuild test` with code coverage. UI tests exercise the happy path
through the sidebar, chat list, composer, and onboarding sheet using
accessibility identifiers set on each view.

## Contributing

Open-source release is planned for Phase 4. In the interim, the repo is
single-author. Issue/PR templates and `CONTRIBUTING.md` arrive with the OSS
cut.

## License

TBD before public release. Personal/internal use until then.
