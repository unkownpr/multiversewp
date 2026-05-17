#!/usr/bin/env bash
#
# scripts/bootstrap.sh — one-shot setup for a fresh checkout.
#
# Auto-installs every CLI dependency we control via Homebrew when it's
# missing, regenerates the Xcode project from project.yml, and builds
# the whatsmeow helper. Safe to run repeatedly.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
warn() { printf "\033[33m! %s\033[0m\n" "$*"; }
fail() { printf "\033[31mx %s\033[0m\n" "$*" >&2; exit 1; }

bold "==> Checking Xcode"
if ! command -v xcodebuild >/dev/null; then
    fail "Xcode is required and cannot be installed automatically. Open the Mac App Store and install Xcode, then re-run this script."
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    fail "xcode-select is pointing at Command Line Tools, not the full Xcode. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

bold "==> Ensuring Homebrew is available"
if ! command -v brew >/dev/null; then
    warn "Homebrew not found — installing"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

REQUIRED_BREW_PACKAGES=(xcodegen swiftlint go protobuf)
MISSING=()
for pkg in "${REQUIRED_BREW_PACKAGES[@]}"; do
    if ! brew list --formula "$pkg" >/dev/null 2>&1; then
        MISSING+=("$pkg")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    bold "==> Installing missing Homebrew packages: ${MISSING[*]}"
    brew install "${MISSING[@]}"
else
    bold "==> All Homebrew dependencies present"
fi

bold "==> Generating Xcode project from project.yml"
xcodegen generate

bold "==> Building whatsmeow-helper"
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
