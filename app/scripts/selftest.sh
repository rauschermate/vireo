#!/bin/sh
# Runs the built app's self-test against a fresh temp folder, including a
# real ⌘B sent to the app's process. Exit code 0 means every step passed.
set -e
cd "$(dirname "$0")/.."
APP="src-tauri/target/release/bundle/macos/Vireo Next.app/Contents/MacOS/vireo"
DIR="$(mktemp -d)"
LOG="$(mktemp)"
VIREO_SELFTEST="$DIR" VIREO_SELFTEST_KEYS=1 "$APP" > "$LOG" 2>&1 &
APP_PID=$!
for _ in $(seq 1 300); do
  if grep -q KEYS-READY "$LOG"; then swift scripts/presskey.swift "$APP_PID" 11; break; fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
  sleep 0.1
done
wait "$APP_PID" || STATUS=$?
grep -E "^(PASS|FAIL)|dialog:" "$LOG"
rm -rf "$DIR" "$LOG"
exit ${STATUS:-0}
