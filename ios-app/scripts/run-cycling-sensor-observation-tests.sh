#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cycling-sensor-observations.XXXXXX")"
trap 'rm -rf "${OUT_DIR}"' EXIT

if [[ "$(uname -s)" == "Darwin" ]]; then
  SWIFTC=(xcrun swiftc)
else
  SWIFTC=(swiftc)
fi

"${SWIFTC[@]}" -parse-as-library -default-isolation MainActor \
  -o "${OUT_DIR}/tests" \
  "${IOS_DIR}/BikeComputer/WorkoutShared/WatchCyclingSensorObservation.swift" \
  "${IOS_DIR}/BikeComputer/WorkoutShared/WatchCyclingSensorObservationPublisher.swift" \
  "${IOS_DIR}/BikeComputerTests/WatchCyclingSensorObservationTests.swift"
"${OUT_DIR}/tests"
