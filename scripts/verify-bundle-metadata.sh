#!/bin/bash
# Fail a build before signing/notarization when the app or Quick Look bundle is
# missing the identity/version metadata LaunchServices and Sparkle rely on.
set -euo pipefail

APP="${1:?usage: verify-bundle-metadata.sh /path/to/Vireo.app}"
APP_PLIST="$APP/Contents/Info.plist"
EXT="$APP/Contents/PlugIns/VireoQuickLook.appex"
EXT_PLIST="$EXT/Contents/Info.plist"
PLIST_BUDDY=/usr/libexec/PlistBuddy

EXPECTED_APP_ID="${VIREO_APP_ID:-com.materauscher.vireo}"
EXPECTED_EXT_ID="${VIREO_QUICKLOOK_ID:-com.materauscher.vireo.QuickLook}"

[[ -f "$APP_PLIST" ]] || { echo "error: missing app Info.plist: $APP_PLIST" >&2; exit 1; }
[[ -f "$EXT_PLIST" ]] || { echo "error: missing Quick Look Info.plist: $EXT_PLIST" >&2; exit 1; }

value() {
    "$PLIST_BUDDY" -c "Print :$2" "$1" 2>/dev/null || true
}

require_value() {
    local plist="$1" key="$2" actual
    actual="$(value "$plist" "$key")"
    [[ -n "$actual" ]] || {
        echo "error: $plist is missing $key" >&2
        exit 1
    }
    printf '%s' "$actual"
}

app_id="$(require_value "$APP_PLIST" CFBundleIdentifier)"
app_exec="$(require_value "$APP_PLIST" CFBundleExecutable)"
app_build="$(require_value "$APP_PLIST" CFBundleVersion)"
app_version="$(require_value "$APP_PLIST" CFBundleShortVersionString)"
ext_id="$(require_value "$EXT_PLIST" CFBundleIdentifier)"
ext_exec="$(require_value "$EXT_PLIST" CFBundleExecutable)"
ext_build="$(require_value "$EXT_PLIST" CFBundleVersion)"
ext_version="$(require_value "$EXT_PLIST" CFBundleShortVersionString)"

[[ "$app_id" == "$EXPECTED_APP_ID" ]] || {
    echo "error: app bundle id is '$app_id', expected '$EXPECTED_APP_ID'" >&2
    exit 1
}
[[ "$ext_id" == "$EXPECTED_EXT_ID" ]] || {
    echo "error: Quick Look bundle id is '$ext_id', expected '$EXPECTED_EXT_ID'" >&2
    exit 1
}
[[ "$app_build" == "$ext_build" ]] || {
    echo "error: build versions differ (app $app_build, Quick Look $ext_build)" >&2
    exit 1
}
[[ "$app_version" == "$ext_version" ]] || {
    echo "error: marketing versions differ (app $app_version, Quick Look $ext_version)" >&2
    exit 1
}
[[ -x "$APP/Contents/MacOS/$app_exec" ]] || {
    echo "error: app executable '$app_exec' is missing" >&2
    exit 1
}
[[ -x "$EXT/Contents/MacOS/$ext_exec" ]] || {
    echo "error: Quick Look executable '$ext_exec' is missing" >&2
    exit 1
}

echo "Verified Vireo $app_version ($app_build): $app_id + $ext_id"
