# whatsmeow-helper

The Go side of MultiverseWP. One process per WhatsApp account. Speaks JSON-over-stdio
to the Swift app (see `Sources/Core/WAClient/WireProtocol.swift`).

## Build

```bash
cd WhatsmeowHelper
go build -o bin/whatsmeow-helper ./...
```

In development, point the Swift client at the locally-built binary with:

```bash
export WHATSMEOW_BIN="$(pwd)/bin/whatsmeow-helper"
```

`HelperBinaryLocator` honours this variable before searching the app bundle and
the project-relative fallback.

## Run

```bash
./bin/whatsmeow-helper --account-id <uuid> --session-dir /path/to/session
```

The helper reads commands line-by-line from stdin and writes events/responses
line-by-line to stdout. stderr is reserved for human-readable diagnostics that
the Swift `WAClientProcess` forwards to its `OSLog` channel.

## Status

The current `main.go` is a **wire-protocol-complete stub**: it emits a fake QR
every 15 seconds and acknowledges sends without actually contacting WhatsApp.
This lets the Swift app build, run, and exercise the IPC path before the
upstream `whatsmeow` dependency is fetched. Replace the simulated paths with
real `*whatsmeow.Client` calls in a follow-up commit.

Tracking todo: wire `Connect`, `SendMessage`, `Download`, and `Events`
on top of `go.mau.fi/whatsmeow`.
