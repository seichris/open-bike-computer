#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."
if ! command -v xcrun >/dev/null 2>&1; then
  echo "Offline route integration tests require macOS and the Apple SDK." >&2
  exit 1
fi
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/offline-route-tests.XXXXXX")"
trap 'rm -rf "${OUT_DIR}"' EXIT
xcrun swiftc -D HOST_TESTING -parse-as-library -o "${OUT_DIR}/tests" \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceOwnership.swift \
  ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/BikeComputerCoordinator.swift \
  ios-app/BikeComputer/BikeComputer/Managers/CurrentLocationManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferSecurity.swift \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceDiagnosticsTransferManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/FirmwareUpdateManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/MapKitRouteAdapter.swift \
  ios-app/BikeComputer/BikeComputer/Managers/NavigationEngine.swift \
  ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift \
  ios-app/BikeComputer/BikeComputer/Services/BicinoServiceSession.swift \
  ios-app/BikeComputer/BikeComputer/Services/ManagedAppAttestClient.swift \
  ios-app/BikeComputer/BikeComputer/Managers/RideDetectionSettingsStore.swift \
  ios-app/BikeComputer/BikeComputer/Managers/WorkoutMetricsStore.swift \
  ios-app/BikeComputer/BikeComputer/Managers/WorkoutDeviceRelay.swift \
  ios-app/BikeComputer/BikeComputer/Models/AppModels.swift \
  ios-app/BikeComputer/BikeComputer/Models/BikeMapStreamFormat.swift \
  ios-app/BikeComputer/BikeComputer/Models/BikeMapStreamProductionTrust.generated.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapPlatform.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapCatalog.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapServiceConfig.swift \
  ios-app/BikeComputer/BikeComputer/Models/SavedRouteNaming.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/CoordinateConverter.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/DeviceCapabilityRetry.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/MapTrackingPolicy.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/RideDiagnostics.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationProtocol.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/RendererBenchmarkProtocol.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/SecureRendererBenchmarkProtocol.swift \
  ios-app/BikeComputer/WorkoutShared/RideAutomationContract.swift \
  ios-app/BikeComputer/WorkoutShared/RideAutomationRuntimeLogic.swift \
  ios-app/BikeComputer/RideShared/NavigationRouteContract.swift \
  ios-app/BikeComputer/RideShared/RouteCoordinateNormalization.swift \
  ios-app/BikeComputer/RideShared/RouteProviderContract.swift \
  ios-app/BikeComputer/RideShared/NavigationRouteArchive.swift \
  ios-app/BikeComputer/RideShared/NavigationGeometry.swift \
  ios-app/BikeComputer/RideShared/NavigationRuntime.swift \
  ios-app/BikeComputer/RideShared/WatchControllerContract.swift \
  ios-app/BikeComputer/RideShared/RideBLEProtocol.generated.swift \
  ios-app/BikeComputer/RideShared/RideBLETransportStateMachine.swift \
  ios-app/BikeComputer/RideShared/WatchDirectBLEContract.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutHeartRateZones.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutValueFormatter.swift \
  ios-app/BikeComputer/WorkoutShared/RideAutomationSourceHealth.generated.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutContract.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutDeviceFrames.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutMetricUnits.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutMirrorRuntimeLogic.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutRuntimeLogic.swift \
  ios-app/BikeComputer/RideShared/SavedDestinationContract.swift \
  ios-app/BikeComputer/RideShared/StravaAthleteRoutes.swift \
  ios-app/BikeComputer/RideShared/StravaRouteURL.swift \
  ios-app/BikeComputer/RideShared/StravaRouteReloadBookmark.swift \
  ios-app/BikeComputer/RideShared/WatchRouteSyncContract.swift \
  ios-app/BikeComputer/RideShared/NavigationRouteFileStore.swift \
  ios-app/BikeComputer/RideShared/GPXRouteImporter.swift \
  ios-app/BikeComputer/BikeComputer/Models/SavedRouteMapSelection.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineRouteSave.swift \
  ios-app/BikeComputer/BikeComputer/Managers/PhoneRouteLibrary.swift \
  ios-app/BikeComputerTests/OfflineRouteSaveTests.swift
"${OUT_DIR}/tests"
