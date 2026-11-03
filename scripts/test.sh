#!/usr/bin/env bash
# Run the swift-testing suite. With Xcode this is plain `swift test`; the Command Line Tools (no Xcode, no
# XCTest) need the extra flags below, which this script adds.
#
# Why the extra flags (verified: CLT 26.3, Swift 6.2.4, macOS 26.7):
#   -Xswiftc -F <CLT>/Library/Developer/Frameworks
#       SwiftPM does not add CLT's Testing.framework to the search path -> "no such module 'Testing'".
#       It MUST be passed on the command line, not only via Package.swift unsafeFlags: SwiftPM's generated
#       runner (<scratch>/debug/<Pkg>PackageTests.derived/runner.swift) wraps the entry point in
#       `#if canImport(Testing)` and that target only sees command-line flags. Otherwise `swift test`
#       silently runs 0 tests and exits 0.
#   -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
#       CLT ships _Testing_Foundation.framework without a swiftmodule (dangling Modules symlink), so a file
#       importing both Testing and Foundation fails with "no such module '_Testing_Foundation'".
#   -Xlinker -rpath -Xlinker <CLT>/Library/Developer/Frameworks
#       Otherwise: dlopen "Library not loaded: @rpath/Testing.framework/Versions/A/Testing".
# A separate --scratch-path keeps these flags from invalidating the normal .build/ cache.
set -euo pipefail

# Toolchain: $DEVELOPER_DIR if set, else the active developer directory (xcode-select). When that one cannot
# run swift (for example an Xcode whose license has not been accepted), fall back to the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! swift --version >/dev/null 2>&1 \
  && [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Guard: TokenBarCore reaches the clock, the home directory, processes, the process
# environment and URLSession only through CoreEnvironment. Only files named Live*.swift may call
# these APIs directly.
# /usr/bin/grep explicitly: `grep` on PATH may be another implementation with different regex rules.
# `Date()`/`Process()` only match as whole identifiers, so e.g. `modificationDate()` is allowed.
violations="$(/usr/bin/grep -rnE '(^|[^A-Za-z0-9_])(Date\(\)|Date\.now|Process\(\))|URLSession\.shared|NSHomeDirectory\(\)|homeDirectoryForCurrentUser|ProcessInfo\.processInfo\.environment' \
  "$ROOT/Sources/TokenBarCore" --include='*.swift' | /usr/bin/grep -vE '/Live[^/]*\.swift:' || true)"
if [[ -n "$violations" ]]; then
  echo "error: TokenBarCore uses clock/home/process/network APIs directly; go through CoreEnvironment:" >&2
  echo "$violations" >&2
  exit 1
fi

FLAGS=()
DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ "$DEV_DIR" == /Library/Developer/CommandLineTools* ]]; then
  FW="$DEV_DIR/Library/Developer/Frameworks"
  FLAGS=(-Xswiftc -F -Xswiftc "$FW"
         -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
         -Xlinker -rpath -Xlinker "$FW")
fi

LOG="$(mktemp -t tokenbar-tests)"
trap 'rm -f "$LOG"' EXIT

set +e
swift test --package-path "$ROOT" --scratch-path "$ROOT/.build-tests" ${FLAGS[@]+"${FLAGS[@]}"} "$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

# Guard against the silent "0 tests, exit 0" failure mode described above.
if [[ $status -eq 0 ]] && ! grep -Eq 'Test run with [1-9][0-9]* tests?' "$LOG"; then
  echo "error: swift test exited 0 but no swift-testing tests ran" >&2
  exit 1
fi
exit "$status"
