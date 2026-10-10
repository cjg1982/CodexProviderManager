#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/cpm-tests.XXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
OUT="$TEST_WORK/CodexProviderManagerTests"
ARCH="$(uname -m)"
swiftc \
  -sdk "$SDK" \
  -target "$ARCH-apple-macosx11.0" \
  -framework Foundation \
  -framework AppKit \
  -framework Security \
  "$ROOT/Sources/ProviderProfile.swift" \
  "$ROOT/Sources/CodexLocation.swift" \
  "$ROOT/Sources/ProfileStore.swift" \
  "$ROOT/Sources/KeychainStore.swift" \
  "$ROOT/Sources/ProviderProbe.swift" \
  "$ROOT/Sources/CodexConfigEditor.swift" \
  "$ROOT/Sources/AtomicConfigWriter.swift" \
  "$ROOT/Sources/ProcessRunner.swift" \
  "$ROOT/Tests/main.swift" \
  -o "$OUT"
"$OUT"
