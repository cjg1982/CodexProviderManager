#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
bash test.sh
bash build.sh
# Explicit source allowlist: never package runtime profiles, config or backups.
python3 scripts/package-source.py
/usr/bin/ditto --norsrc --noextattr --noqtn -c -k --keepParent \
  "dist/Codex Provider Manager.app" "dist/Codex-Provider-Manager-macOS-arm64.zip"
/usr/bin/shasum -a 256 dist/Codex-Provider-Manager-Source.zip dist/Codex-Provider-Manager-macOS-arm64.zip > dist/SHA256SUMS.txt
printf 'Release files are in dist/\n'
