#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${IOS_DIR}/.." && pwd)"
OUT="${TMPDIR:-/tmp}/open-bike-ride-diagnostics-tests"

cd "${REPO_DIR}"
xcrun swiftc \
  -D HOST_TESTING \
  -parse-as-library \
  -o "${OUT}" \
  ios-app/BikeComputer/BikeComputer/Utilities/RideDiagnostics.swift \
  ios-app/BikeComputerTests/RideDiagnosticsHostTests.swift

BUNDLE="$(${OUT})"
python3 tools/ride_diagnostics.py validate "${BUNDLE}"
rm -f "${BUNDLE}"
