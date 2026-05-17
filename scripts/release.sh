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

# ----------------------------------------------------------------------------
# Appcast generation — feeds Sparkle auto-updater
# ----------------------------------------------------------------------------
# We look for `sign_update` inside the SPM-managed Sparkle checkout. If we
# cannot find it (e.g. the developer has not built the app yet), we skip the
# signature and emit a placeholder appcast so the rest of the pipeline keeps
# working. The signature MUST be filled in before pushing to gh-pages.

bold "==> Generating appcast.xml"
APPCAST_PATH="$OUT_DIR/appcast.xml"
DMG_LENGTH=$(stat -f%z "$DMG_PATH")
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
RELEASE_NOTES_RAW=$(git -C "$ROOT_DIR" log -1 --pretty=%B 2>/dev/null || echo "Release ${VERSION}")
# XML-escape minimal special chars in release notes (single line, no CDATA).
RELEASE_NOTES_ESCAPED=$(printf '%s' "$RELEASE_NOTES_RAW" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

SIGN_UPDATE_BIN=""
for candidate in \
    "$HOME/Library/Developer/Xcode/DerivedData"/*/SourcePackages/checkouts/Sparkle/bin/sign_update \
    "$ROOT_DIR/.swiftpm/checkouts/Sparkle/bin/sign_update" \
    "$(which sign_update 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        SIGN_UPDATE_BIN="$candidate"
        break
    fi
done

ED_SIGNATURE=""
if [ -n "$SIGN_UPDATE_BIN" ]; then
    # `sign_update` prints `sparkle:edSignature="…" length="…"`; we extract the
    # signature value and reuse our own length calculation to keep the format
    # stable across Sparkle versions.
    SIGN_OUTPUT=$("$SIGN_UPDATE_BIN" "$DMG_PATH" 2>/dev/null || true)
    ED_SIGNATURE=$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
    if [ -z "$ED_SIGNATURE" ]; then
        echo "warning: sign_update produced no signature. Make sure the private key is in your Keychain (see docs/sparkle-keys.md)."
    fi
else
    echo "warning: sign_update tool not found. Build the project once so SPM fetches Sparkle, then re-run."
fi

if [ -z "$ED_SIGNATURE" ]; then
    ED_SIGNATURE="REPLACE_ME_WITH_ED_SIGNATURE"
fi

# Note on the feed URL: must match SUFeedURL baked into the Info.plist.
DOWNLOAD_URL="https://github.com/semihsilistre/multiversewp/releases/download/v${VERSION}/MultiverseWP-${VERSION}.dmg"

cat >"$APPCAST_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>MultiverseWP</title>
        <link>https://semihsilistre.github.io/multiversewp/appcast.xml</link>
        <description>Auto-update feed for MultiverseWP.</description>
        <language>en</language>
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[${RELEASE_NOTES_ESCAPED}]]></description>
            <enclosure
                url="${DOWNLOAD_URL}"
                sparkle:version="${VERSION}"
                sparkle:shortVersionString="${VERSION}"
                length="${DMG_LENGTH}"
                type="application/octet-stream"
                sparkle:edSignature="${ED_SIGNATURE}" />
        </item>
    </channel>
</rss>
EOF

echo "Appcast: $APPCAST_PATH"
echo "  length:    $DMG_LENGTH bytes"
echo "  sha256:    $DMG_SHA256"
echo "  signature: ${ED_SIGNATURE:0:16}…"
echo
echo "Next step (manual): push the appcast to gh-pages so Sparkle clients pick it up:"
echo "    git -C \"$ROOT_DIR\" checkout gh-pages"
echo "    cp \"$APPCAST_PATH\" appcast.xml"
echo "    git add appcast.xml && git commit -m \"chore: appcast for v${VERSION}\" && git push origin gh-pages"
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
