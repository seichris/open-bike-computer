#!/usr/bin/env bash
set -euo pipefail

DEV_SWIFT_COMPILER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/development/swift_compile.py"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/saved-route-detour-tests.XXXXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT
python3 "${DEV_SWIFT_COMPILER}" saved-route-detour-1 -- \
  -swift-version 6 -strict-concurrency=complete \
  -default-isolation MainActor -D HOST_TESTING -parse-as-library \
  -warnings-as-errors \
  -o "${OUT_DIR}/tests"
"${OUT_DIR}/tests"
