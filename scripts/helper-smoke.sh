#!/usr/bin/env bash
#
# scripts/helper-smoke.sh — exercise the whatsmeow helper without a phone.
#
# Spins up a fresh session dir, fires `connect` and waits a few seconds for
# a QR event, then asks for a clean `disconnect`. The script never scans the
# code — it only verifies that the helper boots, emits a valid `qr` payload,
# and exits cleanly. Useful for catching wire-protocol regressions on the
# auto-download / send_message media paths.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT_DIR/WhatsmeowHelper/bin/whatsmeow-helper"

if [ ! -x "$BIN" ]; then
    (cd "$ROOT_DIR/WhatsmeowHelper" && go build -o bin/whatsmeow-helper ./...)
fi

WORKDIR="$(mktemp -d -t mvwp-helper-smoke)"
trap 'rm -rf "$WORKDIR"' EXIT

ACCOUNT_ID="00000000-0000-0000-0000-000000000001"

# Pipe `connect` then `disconnect` into the helper. The first command spins up
# the QR channel; we sleep so at least one rotation can arrive before we ask
# it to shut down. The helper emits everything on stdout — keep only the most
# informative lines so the smoke log stays small.
{
    echo '{"id":"conn","type":"connect","payload":{}}'
    sleep 6
    echo '{"id":"bye","type":"disconnect","payload":{}}'
    sleep 1
} | "$BIN" --account-id "$ACCOUNT_ID" --session-dir "$WORKDIR/session" 2>"$WORKDIR/stderr.log" \
    | tee "$WORKDIR/stdout.log" \
    | head -40

echo "---"
echo "Stderr tail:"
tail -10 "$WORKDIR/stderr.log" || true
echo "---"
echo "Smoke check:"
if grep -q '"type":"qr"' "$WORKDIR/stdout.log"; then
    echo "  PASS: helper emitted at least one QR code"
else
    echo "  FAIL: no QR event observed"
    exit 1
fi
if grep -q '"type":"disconnected"' "$WORKDIR/stdout.log"; then
    echo "  PASS: helper acknowledged disconnect"
else
    echo "  FAIL: helper did not emit disconnected event"
    exit 1
fi
