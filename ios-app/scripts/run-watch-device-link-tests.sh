#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${SCRIPT_DIR}/bluetooth-tests"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/obc-watch-link.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT

if command -v xcrun >/dev/null 2>&1; then
  SWIFTC=(xcrun swiftc)
else
  SWIFTC=(swiftc)
fi

"${SWIFTC[@]}" -parse-as-library \
  "${IOS_DIR}/BikeComputer/RideShared/RideBLETransportStateMachine.swift" \
  "${TEST_DIR}/RideBLELifecycleTests.swift" \
  -o "${BUILD_DIR}/reducer-tests"
"${BUILD_DIR}/reducer-tests"

if [[ "${1:-}" == "--reducer-only" ]]; then
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--reducer-only]" >&2
  exit 2
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "Adapter tests require macOS SDKs; use --reducer-only on other hosts." >&2
  exit 2
fi

# Replace only the radio boundary. Shared authentication, demand, persistence
# contracts, atomic groups, packet encoding and ACK policies remain production
# code. The temporary module can never be included in an app build.
"${SWIFTC[@]}" -swift-version 5 -emit-module -emit-library \
  -module-name CoreBluetooth \
  -emit-module-path "${BUILD_DIR}/CoreBluetooth.swiftmodule" \
  "${TEST_DIR}/WatchBLETestCoreBluetooth.swift" \
  -o "${BUILD_DIR}/libCoreBluetooth.dylib"

# Same-file extension access avoids public/test-only mutation APIs in the app.
# The entire adapter is compiled: there is no extracted/parallel lifecycle model.
cat "${IOS_DIR}/BikeComputer/BikeComputerWatch/Managers/WatchDeviceLink.swift" \
  "${TEST_DIR}/WatchDeviceLinkTestAccess.swift" \
  > "${BUILD_DIR}/WatchDeviceLinkUnderTest.swift"

cd "${IOS_DIR}"
"${SWIFTC[@]}" -swift-version 5 -parse-as-library \
  -I "${BUILD_DIR}" -L "${BUILD_DIR}" -lCoreBluetooth \
  BikeComputer/RideShared/*.swift \
  BikeComputer/WorkoutShared/RideAutomationContract.swift \
  BikeComputer/WorkoutShared/RideAutomationRuntimeLogic.swift \
  BikeComputer/WorkoutShared/WorkoutHeartRateZones.swift \
  BikeComputer/WorkoutShared/WorkoutValueFormatter.swift \
  BikeComputer/WorkoutShared/WorkoutContract.swift \
  BikeComputer/WorkoutShared/WorkoutDeviceFrames.swift \
  BikeComputer/WorkoutShared/WorkoutMetricUnits.swift \
  BikeComputer/WorkoutShared/WorkoutMirrorRuntimeLogic.swift \
  BikeComputer/WorkoutShared/WorkoutRuntimeLogic.swift \
  "${TEST_DIR}/WatchDeviceLinkTestDependencies.swift" \
  "${BUILD_DIR}/WatchDeviceLinkUnderTest.swift" \
  "${TEST_DIR}/WatchDeviceLinkLifecycleTests.swift" \
  -o "${BUILD_DIR}/adapter-tests"

DYLD_LIBRARY_PATH="${BUILD_DIR}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}" \
  "${BUILD_DIR}/adapter-tests"
