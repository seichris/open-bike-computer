#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${TMPDIR:-/tmp}/open-bike-ride-shared-tests"

cd "${IOS_DIR}"

xcrun swiftc \
  -parse-as-library \
  -o "${OUT}" \
  BikeComputer/RideShared/NavigationRouteContract.swift \
  BikeComputer/RideShared/RouteCoordinateNormalization.swift \
  BikeComputer/RideShared/SavedDestinationContract.swift \
  BikeComputer/RideShared/RouteProviderContract.swift \
  BikeComputer/RideShared/StravaAthleteRoutes.swift \
  BikeComputer/RideShared/StravaRouteURL.swift \
  BikeComputer/RideShared/StravaRouteReloadBookmark.swift \
  BikeComputer/RideShared/NavigationRouteArchive.swift \
  BikeComputer/RideShared/NavigationGeometry.swift \
  BikeComputer/RideShared/NavigationRuntime.swift \
  BikeComputer/RideShared/WatchRouteSyncContract.swift \
  BikeComputer/RideShared/WatchControllerContract.swift \
  BikeComputer/RideShared/RideBLEProtocol.generated.swift \
  BikeComputer/RideShared/RideBLETransportStateMachine.swift \
  BikeComputer/RideShared/WatchDirectBLEContract.swift \
  BikeComputer/RideShared/NavigationRouteFileStore.swift \
  BikeComputer/RideShared/GPXRouteImporter.swift \
  BikeComputerTests/RideSharedTests.swift

"${OUT}"

"${SCRIPT_DIR}/run-watch-device-link-tests.sh"
