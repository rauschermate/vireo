#!/bin/bash
# Assemble a runnable, double-clickable Vireo.app bundle from the SPM build.
# (Notarization / dmg packaging is Phase 5 — this is for local running.)
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product Vireo

BIN_DIR="$(swift build -c "$CONFIG" --product Vireo --show-bin-path)"
BIN="$BIN_DIR/Vireo"
APP="$ROOT/build/Vireo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/Vireo"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# The welcome tour shown on first launch (see AppDelegate.welcomeSampleSource).
cp "$ROOT/samples/welcome.md" "$APP/Contents/Resources/welcome.md"

# Embed Sparkle.framework. The executable links it as @rpath/Sparkle.framework/…;
# SPM drops the built framework next to the binary. Copy it into the standard
# Frameworks dir and point an rpath at it so the bundle launches standalone.
if [ -d "$BIN_DIR/Sparkle.framework" ]; then
    cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Vireo" 2>/dev/null || true
fi

# Ad-hoc sign so macOS will launch it locally. Sign the embedded framework (and
# its nested XPC helpers) first, then the app, so the seals are valid.
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 || true
fi
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
