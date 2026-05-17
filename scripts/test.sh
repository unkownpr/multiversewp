#!/usr/bin/env bash
#
# scripts/test.sh — run unit + UI tests headlessly.
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
    -enableCodeCoverage YES \
    test \
    | xcpretty --color --report html || exit ${PIPESTATUS[0]}
