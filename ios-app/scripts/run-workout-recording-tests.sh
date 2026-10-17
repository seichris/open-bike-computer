#!/usr/bin/env bash
set -euo pipefail

DEV_SWIFT_COMPILER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/development/swift_compile.py"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bicino-recording-tests.XXXXXX")"
trap 'rm -rf "${OUT_DIR}"' EXIT
cd "${REPO_DIR}"
python3 "${DEV_SWIFT_COMPILER}" workout-recording-1 -- \
  -parse-as-library -default-isolation MainActor \
  -o "${OUT_DIR}/ownership"
"${OUT_DIR}/ownership"

# Production coordinator + real Combine/store/reducer with injected recorder
# boundaries. No fake HealthKit implementation and no hardware are involved.
if [[ "$(uname -s)" == Darwin ]]; then
  python3 "${DEV_SWIFT_COMPILER}" workout-recording-coordinator-1 -- \
    -parse-as-library -default-isolation MainActor -D WORKOUT_CONTRACT_HOST \
    -o "${OUT_DIR}/coordinator"
  "${OUT_DIR}/coordinator"
else
  echo "Coordinator integration tests require Apple's Combine on macOS; not run on this host."
fi
