#!/bin/sh
# Builds the Kit and runs its tests. Works with Xcode installed; with only
# Command Line Tools, tests are skipped (CLT ships neither XCTest nor the
# Testing framework) and the build still verifies everything compiles.
set -e
cd "$(dirname "$0")/../MacerodactylKit"

swift build

if xcode-select -p 2>/dev/null | grep -qv CommandLineTools; then
    swift test
else
    echo "note: Command Line Tools only — built OK, skipping tests (need Xcode's toolchain)."
fi
