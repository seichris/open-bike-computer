#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/saved-route-map-tests.XXXXXX")"
trap 'rm -rf "${OUT_DIR}"' EXIT
cd "${REPO_DIR}"

if command -v xcrun >/dev/null 2>&1; then
  SWIFTC=(xcrun swiftc)
else
  SWIFTC=(swiftc)
fi

"${SWIFTC[@]}" -parse-as-library -o "${OUT_DIR}/policy" \
  ios-app/BikeComputer/BikeComputer/Utilities/SavedRouteMapPolicy.swift \
  ios-app/BikeComputerTests/SavedRouteMapPolicyTests.swift
"${OUT_DIR}/policy"

"${SWIFTC[@]}" -parse-as-library -o "${OUT_DIR}/offline-source-policy" \
  ios-app/BikeComputer/RideShared/NavigationRouteContract.swift \
  ios-app/BikeComputer/RideShared/RouteProviderContract.swift \
  ios-app/BikeComputer/RideShared/NavigationGeometry.swift \
  ios-app/BikeComputerTests/OfflineRouteSourceEligibilityTests.swift
"${OUT_DIR}/offline-source-policy"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Native saved-route map integration tests skipped: macOS and an Apple SDK are required."
  exit 0
fi

MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_SUPPORT="${MACOS_SDK}/System/iOSSupport"
xcrun swiftc -D HOST_TESTING -parse-as-library \
  -target "$(uname -m)-apple-ios16.4-macabi" \
  -sdk "${MACOS_SDK}" \
  -F "${IOS_SUPPORT}/System/Library/Frameworks" \
  -I "${IOS_SUPPORT}/usr/lib/swift" \
  -L "${IOS_SUPPORT}/usr/lib/swift" \
  -o "${OUT_DIR}/integration" \
  ios-app/BikeComputer/RideShared/NavigationRouteContract.swift \
  ios-app/BikeComputer/RideShared/RouteCoordinateNormalization.swift \
  ios-app/BikeComputer/RideShared/SavedDestinationContract.swift \
  ios-app/BikeComputer/RideShared/RouteProviderContract.swift \
  ios-app/BikeComputer/RideShared/StravaAthleteRoutes.swift \
  ios-app/BikeComputer/RideShared/StravaRouteURL.swift \
  ios-app/BikeComputer/RideShared/StravaRouteReloadBookmark.swift \
  ios-app/BikeComputer/RideShared/NavigationRouteArchive.swift \
  ios-app/BikeComputer/RideShared/NavigationGeometry.swift \
  ios-app/BikeComputer/RideShared/NavigationRuntime.swift \
  ios-app/BikeComputer/RideShared/WatchRouteSyncContract.swift \
  ios-app/BikeComputer/RideShared/WatchControllerContract.swift \
  ios-app/BikeComputer/RideShared/RideBLEProtocol.generated.swift \
  ios-app/BikeComputer/RideShared/RideBLETransportStateMachine.swift \
  ios-app/BikeComputer/RideShared/WatchDirectBLEContract.swift \
  ios-app/BikeComputer/RideShared/NavigationRouteFileStore.swift \
  ios-app/BikeComputer/RideShared/GPXRouteImporter.swift \
  ios-app/BikeComputer/BikeComputer/Models/AppModels.swift \
  ios-app/BikeComputer/BikeComputer/Models/IPhoneMapAppearance.swift \
  ios-app/BikeComputer/BikeComputer/Models/SavedRouteNaming.swift \
  ios-app/BikeComputer/BikeComputer/Models/SavedRouteMapSelection.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/CoordinateConverter.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/MapTrackingPolicy.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/SavedRouteMapPolicy.swift \
  ios-app/BikeComputer/BikeComputer/Managers/PhoneRouteLibrary.swift \
  ios-app/BikeComputer/BikeComputer/Views/MapView.swift \
  ios-app/BikeComputer/BikeComputer/Views/SavedRouteMapPreview.swift \
  ios-app/BikeComputerTests/SavedRouteMapPreviewTests.swift
"${OUT_DIR}/integration"
