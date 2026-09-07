#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${IOS_DIR}/.." && pwd)"
OUT="${TMPDIR:-/tmp}/open-bike-navigation-tests"

cd "${REPO_DIR}"

RENDERER_SCHEDULER_OUT="${TMPDIR:-/tmp}/open-bike-renderer-scheduler-tests"
xcrun swiftc -D HOST_TESTING -parse-as-library \
  -o "${RENDERER_SCHEDULER_OUT}" \
  ios-app/BikeComputer/BikeComputer/Utilities/RendererBenchmarkReplayScheduler.swift \
  ios-app/BikeComputerTests/RendererBenchmarkReplaySchedulerTests.swift
"${RENDERER_SCHEDULER_OUT}"

RENDERER_WINDOW_OUT="${TMPDIR:-/tmp}/open-bike-renderer-window-tests"
xcrun swiftc -D HOST_TESTING -parse-as-library \
  -o "${RENDERER_WINDOW_OUT}" \
  ios-app/BikeComputer/BikeComputer/Utilities/RendererBenchmarkWindowAdmission.swift \
  ios-app/BikeComputerTests/RendererBenchmarkWindowAdmissionTests.swift
"${RENDERER_WINDOW_OUT}"

RENDERER_DELIVERY_OUT="${TMPDIR:-/tmp}/open-bike-renderer-delivery-tests"
xcrun swiftc -D HOST_TESTING -parse-as-library \
  -o "${RENDERER_DELIVERY_OUT}" \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/RendererBenchmarkOutcome.swift \
  ios-app/BikeComputerTests/RendererDeliveryRegressionTests.swift
"${RENDERER_DELIVERY_OUT}"

xcrun swiftc \
  -D HOST_TESTING \
  -o "${OUT}" \
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
  ios-app/BikeComputer/WorkoutShared/WorkoutContract.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutDeviceFrames.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutMetricUnits.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutMirrorRuntimeLogic.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutRuntimeLogic.swift \
  ios-app/BikeComputerTests/NavigationProtocolTests.swift

"${OUT}"

CYCLING_SENSOR_OUT="${TMPDIR:-/tmp}/open-bike-cycling-sensor-tests"

xcrun swiftc \
  -parse-as-library \
  -default-isolation MainActor \
  -o "${CYCLING_SENSOR_OUT}" \
  ios-app/BikeComputer/WorkoutShared/WorkoutMetricUnits.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutHeartRateZones.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutValueFormatter.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutContract.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutMirrorRuntimeLogic.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutRuntimeLogic.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/RideDiagnostics.swift \
  ios-app/BikeComputer/BikeComputer/Managers/WorkoutMetricsStore.swift \
  ios-app/BikeComputer/BikeComputer/Models/CyclingSensorProfile.swift \
  ios-app/BikeComputer/BikeComputer/Managers/CyclingSensorStore.swift \
  ios-app/BikeComputer/BikeComputer/Managers/CyclingSensorDetectionCoordinator.swift \
  ios-app/BikeComputerTests/CyclingSensorTests.swift

"${CYCLING_SENSOR_OUT}"

CATALYST_OUT="${TMPDIR:-/tmp}/open-bike-destination-callout-tests"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_SUPPORT="${MACOS_SDK}/System/iOSSupport"

xcrun swiftc \
  -D HOST_TESTING \
  -parse-as-library \
  -target "$(uname -m)-apple-ios16.4-macabi" \
  -sdk "${MACOS_SDK}" \
  -F "${IOS_SUPPORT}/System/Library/Frameworks" \
  -I "${IOS_SUPPORT}/usr/lib/swift" \
  -L "${IOS_SUPPORT}/usr/lib/swift" \
  -o "${CATALYST_OUT}" \
  ios-app/BikeComputer/BikeComputer/Models/AppModels.swift \
  ios-app/BikeComputer/BikeComputer/Models/IPhoneMapAppearance.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/CoordinateConverter.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/MapTrackingPolicy.swift \
  ios-app/BikeComputer/BikeComputer/Views/MapView.swift \
  ios-app/BikeComputerTests/DestinationCalloutLayoutTests.swift

"${CATALYST_OUT}"

MAP_APPEARANCE_CATALYST_OUT="${TMPDIR:-/tmp}/open-bike-map-appearance-tests"

xcrun swiftc \
  -D HOST_TESTING \
  -parse-as-library \
  -target "$(uname -m)-apple-ios16.4-macabi" \
  -sdk "${MACOS_SDK}" \
  -F "${IOS_SUPPORT}/System/Library/Frameworks" \
  -I "${IOS_SUPPORT}/usr/lib/swift" \
  -L "${IOS_SUPPORT}/usr/lib/swift" \
  -o "${MAP_APPEARANCE_CATALYST_OUT}" \
  ios-app/BikeComputer/BikeComputer/Models/AppModels.swift \
  ios-app/BikeComputer/BikeComputer/Models/IPhoneMapAppearance.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/CoordinateConverter.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/MapTrackingPolicy.swift \
  ios-app/BikeComputer/BikeComputer/Views/MapView.swift \
  ios-app/BikeComputerTests/MapAppearanceTests.swift

"${MAP_APPEARANCE_CATALYST_OUT}"

PREVIEW_CATALYST_OUT="${TMPDIR:-/tmp}/open-bike-saved-map-preview-tests"

xcrun swiftc \
  -D HOST_TESTING \
  -parse-as-library \
  -target "$(uname -m)-apple-ios16.4-macabi" \
  -sdk "${MACOS_SDK}" \
  -F "${IOS_SUPPORT}/System/Library/Frameworks" \
  -I "${IOS_SUPPORT}/usr/lib/swift" \
  -L "${IOS_SUPPORT}/usr/lib/swift" \
  -o "${PREVIEW_CATALYST_OUT}" \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceOwnership.swift \
  ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferSecurity.swift \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/FirmwareUpdateManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/MapKitRouteAdapter.swift \
  ios-app/BikeComputer/BikeComputer/Managers/NavigationEngine.swift \
  ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift \
  ios-app/BikeComputer/BikeComputer/Services/BicinoServiceSession.swift \
  ios-app/BikeComputer/BikeComputer/Services/ManagedAppAttestClient.swift \
  ios-app/BikeComputer/BikeComputer/Models/AppModels.swift \
  ios-app/BikeComputer/BikeComputer/Models/BikeMapStreamFormat.swift \
  ios-app/BikeComputer/BikeComputer/Models/BikeMapStreamProductionTrust.generated.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapPlatform.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapCatalog.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapServiceConfig.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/CoordinateConverter.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/DeviceCapabilityRetry.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationProtocol.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/RideDiagnostics.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/RendererBenchmarkProtocol.swift \
  ios-app/BikeComputer/WorkoutShared/RideAutomationContract.swift \
  ios-app/BikeComputer/WorkoutShared/RideAutomationRuntimeLogic.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutHeartRateZones.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutValueFormatter.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutContract.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutDeviceFrames.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutMetricUnits.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutMirrorRuntimeLogic.swift \
  ios-app/BikeComputer/WorkoutShared/WorkoutRuntimeLogic.swift \
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
  ios-app/BikeComputerTests/SavedMapPreviewCatalystTests.swift

"${PREVIEW_CATALYST_OUT}"
