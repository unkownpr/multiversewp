#!/usr/bin/env bash
#
# scripts/bootstrap.sh — one-shot setup for a fresh checkout.
#
# Idempotent: safe to run multiple times.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
warn() { printf "\033[33m! %s\033[0m\n" "$*"; }
fail() { printf "\033[31mx %s\033[0m\n" "$*" >&2; exit 1; }

bold "==> Verifying toolchain"

command -v xcodebuild >/dev/null || fail "Xcode is required. Install from the Mac App Store."
command -v xcodegen   >/dev/null || fail "xcodegen missing — install with: brew install xcodegen"
command -v swiftlint  >/dev/null || warn "swiftlint missing — install with: brew install swiftlint (pre-build script will skip silently)"
command -v go         >/dev/null || fail "Go is required for the whatsmeow-helper. Install with: brew install go"

bold "==> Generating Xcode project from project.yml"
xcodegen generate

bold "==> Building whatsmeow-helper (stub mode)"
(
    cd WhatsmeowHelper
    mkdir -p bin
    go build -o bin/whatsmeow-helper ./...
)

bold "==> Done"
cat <<'EOF'

Next steps:
  1. open MultiverseWP.xcodeproj
  2. Select the MultiverseWP scheme.
  3. ⌘R to run; the app auto-opens an onboarding sheet with a stub QR.

To run unit + UI tests headlessly:
  scripts/test.sh

Tip: `export WHATSMEOW_BIN="$(pwd)/WhatsmeowHelper/bin/whatsmeow-helper"`
before launching from the command line so the locator finds the helper.
EOF
