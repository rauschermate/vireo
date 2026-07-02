#!/bin/bash
# Produce a notarized, stapled Vireo.dmg for direct download (eng-design §11).
#
# Requires an Apple Developer ID. Set these first:
#   VIREO_TEAM_ID          your 10-char Apple Team ID
#   VIREO_SIGN_IDENTITY    e.g. "Developer ID Application: Your Name (TEAMID)"
#   VIREO_NOTARY_PROFILE   a notarytool keychain profile you created once via:
#       xcrun notarytool store-credentials VIREO_NOTARY_PROFILE \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
set -euo pipefail

: "${VIREO_TEAM_ID:?set VIREO_TEAM_ID}"
: "${VIREO_SIGN_IDENTITY:?set VIREO_SIGN_IDENTITY}"
: "${VIREO_NOTARY_PROFILE:?set VIREO_NOTARY_PROFILE}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
echo "==> Notarizing the app bundle…"
DITTO_ZIP="build/Vireo.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$DITTO_ZIP"
xcrun notarytool submit "$DITTO_ZIP" --keychain-profile "$VIREO_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> Building dmg…"
"$ROOT/scripts/make-dmg.sh" "$APP" "build/Vireo.dmg"
xcrun stapler staple "build/Vireo.dmg"

echo "==> Done: build/Vireo.dmg (notarized + stapled)"
