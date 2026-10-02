#!/usr/bin/env bash
set -euo pipefail

DEV_SWIFT_COMPILER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/development/swift_compile.py"

RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bicino-swift-check.XXXXXX")"
trap 'rm -rf "$RUN_TMP"' EXIT
export TMPDIR="${RUN_TMP}/"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${TMPDIR:-/tmp}/open-bike-ride-shared-tests"

cd "${IOS_DIR}"

python3 "${DEV_SWIFT_COMPILER}" ride-shared-1 -- \
  -parse-as-library \
  -o "${OUT}"

"${OUT}"

# Exercise the actual Watch adapter with deterministic host boundary doubles.
python3 "${IOS_DIR}/tests/watch-link-host/run.py"
