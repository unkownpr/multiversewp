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

The helper is wired to the real [`go.mau.fi/whatsmeow`](https://pkg.go.dev/go.mau.fi/whatsmeow)
client. On a fresh `--session-dir` it drives the QR pairing flow via
`Client.GetQRChannel` and emits each rotated code as a `qr` event the Swift
side renders. After the phone scans, it emits `pair_success` with the real
JID + push name and reconnects. Incoming `events.Message` payloads are
translated into the frozen wire `message` envelope (text / image / video /
audio / document / sticker), and `events.Receipt` events flow back as
`delivery` updates.

`send_message` calls `Client.SendMessage` with a real `waE2E.Message`. The
session lives in `<session-dir>/store.db` (SQLite, foreign_keys=on) and is
owned by the macOS app, NOT shipped with the binary.

### Still TODO
- `fetch_history` — request a history sync / paginate from the local store
- `download_media` — call `Client.Download` and write to
  `<session-dir>/media/<message_id>`
- `mark_read` — call `Client.MarkRead` with the chat's message IDs

All three currently no-op (or return an explicit error for `download_media`)
so the Swift side is not blocked.
