#!/usr/bin/env bash
# One-time setup for the auto-updater's signing key.
#
# Generates the Sparkle EdDSA key pair used to sign every Vireo update:
#   • the PRIVATE key is stored in your login keychain (never committed),
#   • the PUBLIC key is written into project/App-Info.plist as SUPublicEDKey.
#
# Run this once per developer machine that cuts releases. Re-running is safe —
# it reuses the existing key and just re-syncs the plist. Back the private key
# up somewhere safe; losing it means you can never ship a verifiable update again
# (users would have to reinstall manually).
#
#   Back up:   <sparkle-bin>/generate_keys -x sparkle_private_key.pem   (then store offline)
#   Restore:   <sparkle-bin>/generate_keys -f sparkle_private_key.pem
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/sparkle-tools.sh
source "$ROOT/scripts/sparkle-tools.sh"
BIN="$(sparkle_bin "$ROOT")"
PLIST="$ROOT/project/App-Info.plist"

echo "==> Ensuring an EdDSA key pair exists (private key → login keychain)…"
if ! PUBKEY="$("$BIN/generate_keys" -p 2>/dev/null)" || [ -z "$PUBKEY" ]; then
    "$BIN/generate_keys"
    PUBKEY="$("$BIN/generate_keys" -p)"
fi
echo "    public key: $PUBKEY"

echo "==> Writing SUPublicEDKey into $PLIST"
if /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBKEY" "$PLIST" 2>/dev/null; then :; else
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBKEY" "$PLIST"
fi

echo
echo "done. Commit the updated App-Info.plist so signed release builds trust this key."
echo "The pill will only go live once a release + appcast.xml is published (see scripts/release.sh)."
