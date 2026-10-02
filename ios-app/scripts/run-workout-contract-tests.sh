#!/usr/bin/env bash
set -euo pipefail

DEV_SWIFT_COMPILER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/development/swift_compile.py"

RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bicino-swift-check.XXXXXX")"
trap 'rm -rf "$RUN_TMP"' EXIT
export TMPDIR="${RUN_TMP}/"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/open-bike-workout-contract-tests.XXXXXX")"
trap 'rm -rf "${OUT_DIR}"' EXIT
OUT="${OUT_DIR}/runner"

cd "${REPO_DIR}"
"${SCRIPT_DIR}/run-workout-recording-tests.sh"

python3 "${DEV_SWIFT_COMPILER}" workout-contract-1 -- \
  -parse-as-library \
  -default-isolation MainActor \
  -D WORKOUT_CONTRACT_HOST \
  -o "${OUT}"

"${OUT}"
