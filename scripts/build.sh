#!/usr/bin/env bash
#
# scripts/build.sh — debug build of the macOS app.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

xcodegen generate

xcodebuild \
    -project MultiverseWP.xcodeproj \
    -scheme MultiverseWP \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    build \
    | xcpretty --color || true
