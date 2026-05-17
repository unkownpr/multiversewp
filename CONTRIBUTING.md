# Contributing to MultiverseWP

Thanks for the interest. MultiverseWP is small, opinionated, and built around
a strict architectural contract documented in [`CLAUDE.md`](CLAUDE.md). Read
that first — it is the source of truth.

## Ground rules

- **No automation / spam / mass-DM code.** Every external action is triggered
  by an explicit user gesture or an MCP tool that prompted for approval.
- **No third-party telemetry.** The project is 100% local-first.
- **No WhatsApp logo, wordmark, or trademark glyphs** anywhere in code, art,
  or copy. The string "WhatsApp" as a third-party product name is fine.
- **No force-unwraps (`!`) in production code.** Tests are the only exception.
- **No singletons.** Inject dependencies through protocols.

## Branches

| Pattern             | Purpose                            |
| ------------------- | ---------------------------------- |
| `main`              | Always shippable.                  |
| `feat/<topic>`      | New user-facing feature.           |
| `fix/<topic>`       | Bug fix on a shipped feature.      |
| `refactor/<topic>`  | Internal cleanup, no behavior change. |
| `docs/<topic>`      | Docs-only change.                  |
| `chore/<topic>`     | Build / CI / tooling.              |

One concept per branch. Atomic PRs review faster.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/). Examples:

```
feat(chat): add per-account unread badge
fix(mcp): handle empty tool arguments gracefully
docs(readme): clarify Gatekeeper workaround
refactor(storage): extract MigrationRunner
```

- Subject ≤ 70 chars, imperative mood, no trailing period.
- Body wrapped at 72 columns; explain *why*, not *what*.
- Reference issues with `Refs #N` or `Closes #N`.

## Running tests

```bash
./scripts/test.sh
```

This runs the full XCTest suite (unit + UI) with code coverage. UI tests use
accessibility identifiers — keep them stable on view changes.

For a single feature suite:

```bash
xcodebuild test \
  -project MultiverseWP.xcodeproj \
  -scheme MultiverseWP \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MultiverseWPTests/<YourSuite>
```

## Linting

SwiftLint runs as a pre-build phase. Install it locally:

```bash
brew install swiftlint
```

CI rejects new warnings.

## Filing issues

Open an issue at <https://github.com/semihsilistre/multiversewp/issues> with:

- **What you expected** (one sentence).
- **What happened** (one sentence + console excerpt if relevant).
- **Reproduction** (numbered steps).
- **Environment** (macOS version, app version, Apple silicon vs Intel).

Avoid pasting message content or phone numbers — redact before sharing logs.

## Pull requests

1. Open the PR against `main`.
2. Title in Conventional Commits format.
3. Description: **Why** + **What** + **Test plan**.
4. Keep the diff small. If it exceeds ~400 lines of non-generated code, split
   it.
5. CI must be green. Reviewer assigns once tests pass.

## Code of conduct

Be kind. Be precise. Disagreements happen — argue the code, never the person.
Harassment, discrimination, or personal attacks earn a permanent ban from the
project at the maintainer's discretion. We will adopt the Contributor Covenant
in full ahead of the v1.0 public release.

## Maintainer

Semih Silistre — <https://ssilistre.dev>
