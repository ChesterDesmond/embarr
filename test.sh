#!/bin/bash
# Run the tests. With only Command Line Tools installed, swift-testing's macro plugin lives in a folder the
# build does not search, so it is passed by hand (see ~/.claude/papercuts.md, 2026-11-05).
set -euo pipefail
cd "$(dirname "$0")"
exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
