#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${TMPDIR:-/tmp}/open-bike-watch-online-navigation-tests"

cd "${IOS_DIR}"

xcrun swiftc \
  -parse-as-library \
  -warnings-as-errors \
  -default-isolation MainActor \
  -o "${OUT}" \
  BikeComputer/RideShared/NavigationRouteContract.swift \
  BikeComputer/RideShared/RouteProviderContract.swift \
  BikeComputer/RideShared/NavigationGeometry.swift \
  BikeComputer/RideShared/NavigationRuntime.swift \
  BikeComputer/RideShared/NavigationRouteArchive.swift \
  BikeComputer/RideShared/WatchRouteSyncContract.swift \
  BikeComputer/RideShared/NavigationRouteFileStore.swift \
  BikeComputer/RideShared/RouteCoordinateNormalization.swift \
  BikeComputer/RideShared/SavedDestinationContract.swift \
  BikeComputer/BikeComputerWatch/Managers/WatchRouteLibrary.swift \
  BikeComputer/BikeComputerWatch/Managers/WatchNavigationJournal.swift \
  BikeComputer/BikeComputerWatch/Managers/WatchNavigationSettingsStore.swift \
  BikeComputer/BikeComputerWatch/Managers/WatchFavoriteStore.swift \
  BikeComputer/BikeComputerWatch/Managers/WatchNetworkPathMonitor.swift \
  BikeComputer/BikeComputerWatch/Managers/WatchNavigationManager.swift \
  BikeComputerTests/WatchOnlineNavigationTests.swift

"${OUT}"
