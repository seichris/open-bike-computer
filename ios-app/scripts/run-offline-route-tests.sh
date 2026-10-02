#!/usr/bin/env bash
set -euo pipefail

DEV_SWIFT_COMPILER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/development/swift_compile.py"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."
if ! command -v xcrun >/dev/null 2>&1; then
  echo "Offline route integration tests require macOS and the Apple SDK." >&2
  exit 1
fi
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/offline-route-tests.XXXXXX")"
trap 'rm -rf "${OUT_DIR}"' EXIT
python3 "${DEV_SWIFT_COMPILER}" offline-route-1 -- \
  -D HOST_TESTING -parse-as-library -o "${OUT_DIR}/tests"
"${OUT_DIR}/tests"
