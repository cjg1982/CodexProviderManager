#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Codex Provider Manager"
BUNDLE="$ROOT/dist/$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"
BINARY="$CONTENTS/MacOS/CodexProviderManager"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

command -v swiftc >/dev/null
command -v plutil >/dev/null
command -v codesign >/dev/null

rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist"

swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx11.0 \
  -O \
  -whole-module-optimization \
  -framework AppKit \
  -framework Foundation \
  -framework Security \
  "$ROOT"/Sources/*.swift \
  -o "$BINARY"

chmod 755 "$BINARY"
codesign --force --sign - --timestamp=none "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
printf 'Built: %s\n' "$BUNDLE"
