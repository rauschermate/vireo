#!/bin/sh
# Exports the same deterministic fixtures that Vireo's Swift benchmark uses,
# so both editors are measured on identical input.
set -e
cd "$(dirname "$0")/../.."
swift build -c release --product VireoSnapshot
.build/release/VireoSnapshot --write-benchmark-fixtures spike/fixtures
cp samples/welcome.md spike/fixtures/welcome.md
