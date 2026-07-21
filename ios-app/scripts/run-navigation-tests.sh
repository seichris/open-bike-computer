#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${IOS_DIR}/.." && pwd)"
OUT="${TMPDIR:-/tmp}/open-bike-navigation-tests"

cd "${REPO_DIR}"

xcrun swiftc \
  -D HOST_TESTING \
  -o "${OUT}" \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceOwnership.swift \
  ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/BikeComputerCoordinator.swift \
  ios-app/BikeComputer/BikeComputer/Managers/CurrentLocationManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/FirmwareUpdateManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/NavigationEngine.swift \
  ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/WorkoutMetricsStore.swift \
  ios-app/BikeComputer/BikeComputer/Managers/WorkoutDeviceRelay.swift \
  ios-app/BikeComputer/BikeComputer/Models/AppModels.swift \
  ios-app/BikeComputer/BikeComputer/Models/BikeMapStreamFormat.swift \
  ios-app/BikeComputer/BikeComputer/Models/BikeMapStreamProductionTrust.generated.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapPlatform.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapServiceConfig.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/CoordinateConverter.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/DeviceCapabilityRetry.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/MapTrackingPolicy.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationProtocol.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutContract.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutMetricUnits.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutMirrorRuntimeLogic.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutRuntimeLogic.swift \
  ios-app/BikeComputerTests/NavigationProtocolTests.swift

"${OUT}"

CATALYST_OUT="${TMPDIR:-/tmp}/open-bike-destination-callout-tests"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_SUPPORT="${MACOS_SDK}/System/iOSSupport"

xcrun swiftc \
  -D HOST_TESTING \
  -parse-as-library \
  -target "$(uname -m)-apple-ios15.0-macabi" \
  -sdk "${MACOS_SDK}" \
  -F "${IOS_SUPPORT}/System/Library/Frameworks" \
  -I "${IOS_SUPPORT}/usr/lib/swift" \
  -L "${IOS_SUPPORT}/usr/lib/swift" \
  -o "${CATALYST_OUT}" \
  ios-app/BikeComputer/BikeComputer/Models/AppModels.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/CoordinateConverter.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/MapTrackingPolicy.swift \
  ios-app/BikeComputer/BikeComputer/Views/MapView.swift \
  ios-app/BikeComputerTests/DestinationCalloutLayoutTests.swift

"${CATALYST_OUT}"

PREVIEW_CATALYST_OUT="${TMPDIR:-/tmp}/open-bike-saved-map-preview-tests"

xcrun swiftc \
  -D HOST_TESTING \
  -parse-as-library \
  -target "$(uname -m)-apple-ios15.0-macabi" \
  -sdk "${MACOS_SDK}" \
  -F "${IOS_SUPPORT}/System/Library/Frameworks" \
  -I "${IOS_SUPPORT}/usr/lib/swift" \
  -L "${IOS_SUPPORT}/usr/lib/swift" \
  -o "${PREVIEW_CATALYST_OUT}" \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceOwnership.swift \
  ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/FirmwareUpdateManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/NavigationEngine.swift \
  ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift \
  ios-app/BikeComputer/BikeComputer/Models/AppModels.swift \
  ios-app/BikeComputer/BikeComputer/Models/BikeMapStreamFormat.swift \
  ios-app/BikeComputer/BikeComputer/Models/BikeMapStreamProductionTrust.generated.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapPlatform.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapServiceConfig.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/CoordinateConverter.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/DeviceCapabilityRetry.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationProtocol.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift \
  ios-app/BikeComputerTests/SavedMapPreviewCatalystTests.swift

"${PREVIEW_CATALYST_OUT}"
