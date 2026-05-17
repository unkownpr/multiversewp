#!/usr/bin/env bash
#
# scripts/release.sh — produce a distributable MultiverseWP-<version>.dmg.
#
# Builds the Release configuration, bundles the helper, ad-hoc signs the
# app, and packages everything into a compressed DMG inside ./release/.
#
# Requires: Xcode, xcodegen, Go.
# Notarization (com.apple.security.cs.app-sandbox + Apple Developer team) is
# applied automatically when DEVELOPMENT_TEAM env var is set; otherwise the
# DMG ships ad-hoc signed (end-user has to right-click → Open the first
# time to bypass Gatekeeper). See README "Install" section.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${MULTIVERSEWP_VERSION:-0.1.0}"
SCHEME="MultiverseWP"
CONFIG="Release"
ARCH="$(uname -m)"
DEST="platform=macOS,arch=${ARCH}"

OUT_DIR="$ROOT_DIR/release"
EXPORT_DIR="$OUT_DIR/export"
DMG_PATH="$OUT_DIR/MultiverseWP-${VERSION}.dmg"
APP_NAME="MultiverseWP.app"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }

bold "==> Cleaning $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$EXPORT_DIR"

bold "==> Regenerating Xcode project"
xcodegen generate >/dev/null

bold "==> Archiving $SCHEME ($CONFIG, $ARCH)"
ARCHIVE_PATH="$OUT_DIR/$SCHEME.xcarchive"
EXTRA_SIGN_ARGS=()
if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
    EXTRA_SIGN_ARGS+=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild \
    -project MultiverseWP.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DEST" \
    -archivePath "$ARCHIVE_PATH" \
    "${EXTRA_SIGN_ARGS[@]}" \
    archive | tail -3

bold "==> Copying .app out of archive"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME" "$EXPORT_DIR/"

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    bold "==> Notarizing (DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM)"
    codesign --force --deep --sign "$DEVELOPMENT_TEAM" --options runtime --entitlements Resources/MultiverseWP.entitlements "$EXPORT_DIR/$APP_NAME"
    if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ]; then
        ditto -c -k --keepParent "$EXPORT_DIR/$APP_NAME" "$OUT_DIR/notary.zip"
        xcrun notarytool submit "$OUT_DIR/notary.zip" \
            --apple-id "$NOTARY_APPLE_ID" \
            --password "$NOTARY_PASSWORD" \
            --team-id "$NOTARY_TEAM_ID" \
            --wait
        xcrun stapler staple "$EXPORT_DIR/$APP_NAME"
        rm -f "$OUT_DIR/notary.zip"
    fi
else
    bold "==> Ad-hoc signing (no Apple Developer team set)"
    codesign --force --deep --sign - "$EXPORT_DIR/$APP_NAME"
fi

bold "==> Building DMG → $DMG_PATH"
TMP_DMG="$OUT_DIR/_staging.dmg"
hdiutil create -volname "MultiverseWP" \
    -srcfolder "$EXPORT_DIR" \
    -ov -format UDZO \
    "$TMP_DMG" >/dev/null
mv "$TMP_DMG" "$DMG_PATH"

SIZE=$(du -sh "$DMG_PATH" | awk '{print $1}')
bold "==> Done"
echo "Output: $DMG_PATH ($SIZE)"
echo
if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
    cat <<'EOF'
NOTE: The DMG is ad-hoc signed. First-time users will see Gatekeeper:
    "MultiverseWP.app can't be opened because Apple cannot check it"
They must right-click the app → Open → Open in the confirmation dialog.

For seamless launch ship with a notarized build:
    DEVELOPMENT_TEAM=YOURTEAM \
    NOTARY_APPLE_ID=you@apple.id NOTARY_PASSWORD=app-spec-pw NOTARY_TEAM_ID=YOURTEAM \
    scripts/release.sh
EOF
fi
