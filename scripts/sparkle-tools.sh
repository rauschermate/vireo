#!/usr/bin/env bash
# Shared helper: resolve the path to Sparkle's bundled CLI tools
# (generate_keys, sign_update, generate_appcast), fetching the SPM artifact if
# it isn't unpacked yet. Source this, then call `sparkle_bin <repo-root>`.

sparkle_bin() {
    local root="$1"
    local bin="$root/.build/artifacts/sparkle/Sparkle/bin"
    if [ ! -x "$bin/generate_keys" ]; then
        ( cd "$root" && swift package resolve >/dev/null 2>&1 ) || true
    fi
    if [ ! -x "$bin/generate_keys" ]; then
        echo "error: Sparkle CLI tools not found at $bin (run 'swift package resolve')" >&2
        return 1
    fi
    echo "$bin"
}
