#!/bin/bash
# Package a built Vireo.app into a distributable .dmg (drag-to-Applications).
# Usage: scripts/make-dmg.sh <path/to/Vireo.app> [output.dmg]
set -euo pipefail

APP="${1:?usage: make-dmg.sh <Vireo.app> [out.dmg]}"
OUT="${2:-build/Vireo.dmg}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
hdiutil create \
    -volname "Vireo $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$OUT"

rm -rf "$STAGE"
echo "Created $OUT"
