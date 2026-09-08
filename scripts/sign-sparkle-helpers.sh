#!/bin/bash
# Xcode build phase. "Code Sign On Copy" signs Sparkle.framework but not the
# helpers nested inside it (Autoupdate, Updater.app, the XPC services), so they
# keep Sparkle's ad-hoc signature and notarization rejects the app. Re-sign them
# with the build's identity before Xcode seals the app. Recipe from
# https://sparkle-project.org/documentation/sandboxing/#code-signing
set -euo pipefail

[[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]] || exit 0
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] || exit 0

FRAMEWORK="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
if [[ ! -d "$FRAMEWORK" ]]; then
    echo "error: $FRAMEWORK is not embedded yet; check the build phase order" >&2
    exit 1
fi
VERSION_DIR="$FRAMEWORK/Versions/B"

sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }

sign --preserve-metadata=entitlements "$VERSION_DIR/XPCServices/Downloader.xpc"
sign "$VERSION_DIR/XPCServices/Installer.xpc"
sign "$VERSION_DIR/Autoupdate"
sign "$VERSION_DIR/Updater.app"
sign "$FRAMEWORK"
