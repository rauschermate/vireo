#!/bin/bash
# Build Vireo.app (with the embedded Quick Look extension) via the Xcode project.
# Regenerates the project from project.yml first. Ad-hoc signed for local use;
# pass a Developer ID to scripts/release.sh for a notarizable build.
#
# Usage: scripts/build-app-xcode.sh [Debug|Release]
set -euo pipefail

CONFIG="${1:-Release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null || { echo "xcodegen required: brew install xcodegen"; exit 1; }

xcodegen generate
xcodebuild -project Vireo.xcodeproj -scheme Vireo -configuration "$CONFIG" \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO build

SRC="build/DerivedData/Build/Products/$CONFIG/Vireo.app"
DEST="build/Vireo.app"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
"$ROOT/scripts/verify-bundle-metadata.sh" "$DEST"
codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true
echo "Built $DEST (with Quick Look extension in Contents/PlugIns)"
