#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bicino-recording-tests.XXXXXX")"
trap 'rm -rf "${OUT_DIR}"' EXIT
cd "${REPO_DIR}"
if command -v xcrun >/dev/null 2>&1; then
  SWIFTC=(xcrun swiftc)
else
  SWIFTC=(swiftc)
fi
"${SWIFTC[@]}" -parse-as-library -default-isolation MainActor \
  ios-app/BikeComputer/WorkoutShared/WorkoutWatchAvailability.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutRecordingOwnership.swift \
  ios-app/BikeComputer/BikeComputer/Managers/WorkoutRecordingStore.swift \
  ios-app/BikeComputerTests/WorkoutRecordingOwnershipTests.swift \
  -o "${OUT_DIR}/ownership"
"${OUT_DIR}/ownership"

# Production coordinator + real Combine/store/reducer with injected recorder
# boundaries. No fake HealthKit implementation and no hardware are involved.
if [[ "$(uname -s)" == Darwin ]]; then
  "${SWIFTC[@]}" -parse-as-library -default-isolation MainActor -D WORKOUT_CONTRACT_HOST \
  ios-app/BikeComputer/WorkoutShared/WorkoutMetricUnits.swift \
  ios-app/BikeComputer/WorkoutShared/RideAutomationSourceHealth.generated.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutHeartRateZones.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutNativeZones.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutZoneWire.generated.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutZoneDeviceProtocol.swift \
  ios-app/BikeComputer/WorkoutShared/RideAutomationContract.swift \
  ios-app/BikeComputer/WorkoutShared/RideAutomationRuntimeLogic.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutContract.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutDeviceFrames.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutMirrorRuntimeLogic.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutRuntimeLogic.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutValueFormatter.swift \
  ios-app/BikeComputer/WorkoutShared/WatchWorkoutLaunchRequest.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/RideDiagnostics.swift \
  ios-app/BikeComputer/BikeComputer/Managers/RideDetectionSettingsStore.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutWatchAvailability.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutRecordingOwnership.swift \
  ios-app/BikeComputer/BikeComputer/Managers/WorkoutMetricsStore.swift \
  ios-app/BikeComputer/BikeComputer/Managers/WorkoutRecordingStore.swift \
  ios-app/BikeComputer/BikeComputer/Managers/WorkoutSessionCoordinator.swift \
  ios-app/BikeComputerTests/WorkoutSessionCoordinatorTests.swift \
  -o "${OUT_DIR}/coordinator"
  "${OUT_DIR}/coordinator"
else
  echo "Coordinator integration tests require Apple's Combine on macOS; not run on this host."
fi
