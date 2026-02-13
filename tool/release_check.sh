#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

dart format --set-exit-if-changed .
dart analyze
dart test

if command -v google-chrome >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1; then
  dart test -p chrome
else
  echo "Chrome executable not found; skipping browser tests in local release_check."
fi

dart doc --validate-links
./tool/generate_parser.sh

git diff --exit-code
