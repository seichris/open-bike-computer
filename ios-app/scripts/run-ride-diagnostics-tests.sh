#!/usr/bin/env bash
set -euo pipefail

DEV_SWIFT_COMPILER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/development/swift_compile.py"

RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bicino-swift-check.XXXXXX")"
trap 'rm -rf "$RUN_TMP"' EXIT
export TMPDIR="${RUN_TMP}/"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${IOS_DIR}/.." && pwd)"
OUT="${TMPDIR:-/tmp}/open-bike-ride-diagnostics-tests"

cd "${REPO_DIR}"
python3 "${DEV_SWIFT_COMPILER}" ride-diagnostics-1 -- \
  -D HOST_TESTING \
  -parse-as-library \
  -o "${OUT}"

BUNDLE="$(${OUT})"
python3 tools/ride_diagnostics.py validate "${BUNDLE}"
rm -f "${BUNDLE}"
