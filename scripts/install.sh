#!/usr/bin/env bash
# Install Vireo into /Applications and make it the default handler for
# markdown files, so double-clicking a .md/.markdown file in Finder opens it
# in Vireo (as a new tab in the running window, or a fresh launch).
#
# Usage:
#   ./scripts/install.sh            # quick SPM bundle (no Quick Look extension)
#   ./scripts/install.sh --full     # full app + Quick Look extension (needs xcodegen)
#
# Re-run after making changes to dogfood the latest build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/Vireo.app"
BUNDLE_ID="com.materauscher.vireo"
MD_UTI="net.daringfireball.markdown"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 1. Build.
if [[ "${1:-}" == "--full" ]]; then
    "$ROOT/scripts/build-app-xcode.sh" Debug
    SRC="$ROOT/build/DerivedData/Build/Products/Debug/Vireo.app"
else
    "$ROOT/scripts/build-app.sh"
    SRC="$ROOT/build/Vireo.app"
fi
[[ -d "$SRC" ]] || { echo "build produced no app at $SRC" >&2; exit 1; }

# 2. Stop any running instance so the copy isn't in use.
pkill -x Vireo 2>/dev/null || true
sleep 1

# 3. Install into /Applications (a stable path Launch Services won't confuse
#    with the moving dev-build locations).
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "installed $DEST"

# 4. Deregister the dev copies so their identical bundle id can't hijack the
#    default handler (files are left untouched).
"$LSREG" -u "$ROOT/build/Vireo.app" 2>/dev/null || true
"$LSREG" -u "$ROOT/build/DerivedData/Build/Products/Debug/Vireo.app" 2>/dev/null || true

# 5. Register the installed copy.
"$LSREG" -f "$DEST"

# 6. Make it the default handler for markdown (covers .md and .markdown, which
#    both map to the net.daringfireball.markdown UTI).
swift - "$DEST" "$MD_UTI" <<'SWIFT'
import AppKit
import UniformTypeIdentifiers
let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let uti = UTType(CommandLine.arguments[2])!
let sem = DispatchSemaphore(value: 0)
NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: uti) { err in
    if let err { print("warning: could not set default handler: \(err)") }
    sem.signal()
}
_ = sem.wait(timeout: .now() + 10)
let resolved = NSWorkspace.shared.urlForApplication(toOpen: uti)?.path ?? "none"
print("default markdown handler: \(resolved)")
SWIFT

echo "done — double-click a .md file in Finder to open it in Vireo."
