#!/bin/bash
# Produce a notarized, stapled Vireo.dmg for direct download (eng-design §11),
# then sign it for Sparkle and generate the appcast the auto-updater polls.
#
# Requires an Apple Developer ID. Set these first:
#   VIREO_TEAM_ID          your 10-char Apple Team ID
#   VIREO_SIGN_IDENTITY    e.g. "Developer ID Application: Your Name (TEAMID)"
#   VIREO_NOTARY_PROFILE   a notarytool keychain profile you created once via:
#       xcrun notarytool store-credentials VIREO_NOTARY_PROFILE \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# The Sparkle EdDSA signing key must already exist (run scripts/updater-keys.sh
# once). Pass --publish to create the GitHub release and upload the DMG + appcast;
# without it the artifacts are built locally and the publish command is printed.
set -euo pipefail

: "${VIREO_TEAM_ID:?set VIREO_TEAM_ID}"
: "${VIREO_SIGN_IDENTITY:?set VIREO_SIGN_IDENTITY}"
: "${VIREO_NOTARY_PROFILE:?set VIREO_NOTARY_PROFILE}"

PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

REPO="rauschermate/vireo"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/sparkle-tools.sh
source "$ROOT/scripts/sparkle-tools.sh"
cd "$ROOT"

echo "==> Generating project + archiving (Developer ID signed)…"
xcodegen generate
xcodebuild -project Vireo.xcodeproj -scheme Vireo -configuration Release \
    -derivedDataPath build/DerivedData \
    -archivePath build/Vireo.xcarchive \
    DEVELOPMENT_TEAM="$VIREO_TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$VIREO_SIGN_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    archive

APP="build/Vireo.xcarchive/Products/Applications/Vireo.app"
"$ROOT/scripts/verify-bundle-metadata.sh" "$APP"
echo "==> Notarizing the app bundle…"
DITTO_ZIP="build/Vireo.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$DITTO_ZIP"
xcrun notarytool submit "$DITTO_ZIP" --keychain-profile "$VIREO_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> Building, signing, notarizing, and stapling the dmg…"
"$ROOT/scripts/make-dmg.sh" "$APP" "build/Vireo.dmg"
# The app's ticket does not cover the disk image. Gatekeeper warns on an
# unnotarized dmg, and stapler needs a ticket for the dmg itself.
codesign --sign "$VIREO_SIGN_IDENTITY" --timestamp "build/Vireo.dmg"
xcrun notarytool submit "build/Vireo.dmg" --keychain-profile "$VIREO_NOTARY_PROFILE" --wait
xcrun stapler staple "build/Vireo.dmg"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
TAG="v$VERSION"

echo "==> Signing update + generating appcast for ${TAG}…"
if ! grep -q '<string>[A-Za-z0-9+/=]\{20,\}</string>' project/App-Info.plist; then
    echo "error: SUPublicEDKey looks empty in project/App-Info.plist — run scripts/updater-keys.sh first." >&2
    exit 1
fi
BIN="$(sparkle_bin "$ROOT")"
APPCAST_DIR="build/appcast"
rm -rf "$APPCAST_DIR"; mkdir -p "$APPCAST_DIR"
cp "build/Vireo.dmg" "$APPCAST_DIR/"
# generate_appcast signs each archive with the keychain private key and writes
# appcast.xml. Enclosure URLs are prefixed with this release's asset URL; the
# feed itself is served from the "latest release" alias (see SUFeedURL).
"$BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    "$APPCAST_DIR"

echo "==> Done:"
echo "    build/Vireo.dmg           (notarized + stapled)"
echo "    $APPCAST_DIR/appcast.xml  (Sparkle feed)"

if [[ "$PUBLISH" == "1" ]]; then
    echo "==> Publishing GitHub release ${TAG}…"
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        gh release upload "$TAG" "build/Vireo.dmg" "$APPCAST_DIR/appcast.xml" \
            --repo "$REPO" --clobber
    else
        gh release create "$TAG" "build/Vireo.dmg" "$APPCAST_DIR/appcast.xml" \
            --repo "$REPO" --title "Vireo $VERSION" --generate-notes
    fi
    echo "==> Published. Existing users' pill will surface within SUScheduledCheckInterval."
else
    echo
    echo "Not published (pass --publish to upload). To publish manually:"
    echo "  gh release create $TAG build/Vireo.dmg $APPCAST_DIR/appcast.xml \\"
    echo "    --repo $REPO --title \"Vireo $VERSION\" --generate-notes"
fi
