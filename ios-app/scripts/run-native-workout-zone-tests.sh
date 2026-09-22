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
python3 - "$ROOT" "$OUT/ZoneDispatch.swift" <<'PYTHON'
from pathlib import Path
import sys
text = (Path(sys.argv[1]) / "ios-app/BikeComputer/RideShared/WatchDirectBLEContract.swift").read_text()
start = text.index("struct RideBLEZoneDispatch:")
end = text.index("\nstruct WatchBLEOutboundWriteV1:", start)
Path(sys.argv[2]).write_text("import Foundation\n" + text[start:end])
PYTHON
cd "$ROOT/ios-app/BikeComputer/WorkoutShared"
"${SWIFTC[@]}" -parse-as-library -D NATIVE_WORKOUT_ZONE_HOST \
  WorkoutMetricUnits.swift RideAutomationSourceHealth.generated.swift \
  WorkoutHeartRateZones.swift WorkoutNativeZones.swift \
  WorkoutZoneWire.generated.swift WorkoutZoneDeviceProtocol.swift \
  ../RideShared/RideBLEProtocol.generated.swift "$OUT/ZoneDispatch.swift" \
  RideAutomationContract.swift \
  WorkoutContract.swift WorkoutDeviceFrames.swift WorkoutMirrorRuntimeLogic.swift \
  WorkoutRuntimeLogic.swift WorkoutValueFormatter.swift WorkoutWatchAvailability.swift \
  WatchWorkoutLaunchRequest.swift \
  ../../BikeComputerTests/WorkoutNativeZoneTests.swift \
  -o "$OUT/tests"
"$OUT/tests" "$ROOT/protocol/fixtures/workout-zones-v1.json"
