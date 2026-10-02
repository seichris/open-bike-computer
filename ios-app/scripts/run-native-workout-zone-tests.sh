#!/usr/bin/env bash
set -euo pipefail

DEV_SWIFT_COMPILER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/development/swift_compile.py"
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
python3 "${DEV_SWIFT_COMPILER}" native-workout-zone-1 -- \
  -parse-as-library -D NATIVE_WORKOUT_ZONE_HOST \
  WorkoutMetricUnits.swift RideAutomationSourceHealth.generated.swift \
  WorkoutHeartRateZones.swift WorkoutNativeZones.swift \
  WorkoutZoneWire.generated.swift WorkoutZoneDeviceProtocol.swift \
  ../RideShared/RideBLEProtocol.generated.swift ../RideShared/RideBLEZoneDispatch.swift \
  WorkoutContract.swift WorkoutDeviceFrames.swift WorkoutMirrorRuntimeLogic.swift \
  WorkoutRuntimeLogic.swift WorkoutValueFormatter.swift WorkoutWatchAvailability.swift \
  -o "$OUT/tests"
"$OUT/tests" "$ROOT/protocol/fixtures/workout-zones-v1.json"
