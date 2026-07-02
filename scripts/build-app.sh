#!/bin/bash
# Assemble a runnable, double-clickable Vireo.app bundle from the SPM build.
# (Notarization / dmg packaging is Phase 5 — this is for local running.)
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product Vireo

BIN="$(swift build -c "$CONFIG" --product Vireo --show-bin-path)/Vireo"
APP="$ROOT/build/Vireo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Vireo"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Ad-hoc sign so macOS will launch it locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
