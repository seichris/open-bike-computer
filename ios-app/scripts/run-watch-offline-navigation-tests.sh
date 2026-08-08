#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${TMPDIR:-/tmp}/open-bike-watch-offline-navigation-tests"

cd "${IOS_DIR}"

xcrun swiftc \
  -parse-as-library \
  -o "${OUT}" \
  BikeComputer/RideShared/NavigationRouteContract.swift \
  BikeComputer/RideShared/RouteProviderContract.swift \
  BikeComputer/RideShared/NavigationRouteArchive.swift \
  BikeComputer/RideShared/NavigationGeometry.swift \
  BikeComputer/RideShared/NavigationRuntime.swift \
  BikeComputer/RideShared/WatchRouteSyncContract.swift \
  BikeComputer/RideShared/NavigationRouteFileStore.swift \
  BikeComputer/BikeComputerWatch/Managers/WatchRouteLibrary.swift \
  BikeComputer/BikeComputerWatch/Managers/WatchNavigationJournal.swift \
  BikeComputerTests/WatchOfflineNavigationTests.swift

"${OUT}"
