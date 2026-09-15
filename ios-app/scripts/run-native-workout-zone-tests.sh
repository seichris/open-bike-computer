#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/bicino-native-zones.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
if [[ "$(uname -s)" == Darwin ]]; then
  SWIFTC=(xcrun swiftc)
else
  SWIFTC=(swiftc)
fi
cd "$ROOT/ios-app/BikeComputer/WorkoutShared"
"${SWIFTC[@]}" -parse-as-library -D NATIVE_WORKOUT_ZONE_HOST \
  WorkoutMetricUnits.swift RideAutomationSourceHealth.generated.swift \
  WorkoutHeartRateZones.swift WorkoutNativeZones.swift \
  RideAutomationContract.swift \
  WorkoutContract.swift WorkoutDeviceFrames.swift WorkoutMirrorRuntimeLogic.swift \
  WorkoutRuntimeLogic.swift WorkoutValueFormatter.swift WorkoutWatchAvailability.swift \
  WatchWorkoutLaunchRequest.swift \
  ../../BikeComputerTests/WorkoutNativeZoneTests.swift \
  -o "$OUT/tests"
"$OUT/tests"
