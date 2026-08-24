#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONLY_TESTING="WorkoutContractiOSTests/RideDiagnosticsTests" \
  "${SCRIPT_DIR}/run-workout-platform-tests.sh" ios
