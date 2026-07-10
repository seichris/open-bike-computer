#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${IOS_DIR}/.." && pwd)"
OUT="${TMPDIR:-/tmp}/open-bike-navigation-tests"

cd "${REPO_DIR}"

xcrun swiftc \
  -o "${OUT}" \
  ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/FirmwareUpdateManager.swift \
  ios-app/BikeComputer/BikeComputer/Managers/NavigationEngine.swift \
  ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift \
  ios-app/BikeComputer/BikeComputer/Models/AppModels.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapPlatform.swift \
  ios-app/BikeComputer/BikeComputer/Models/OfflineMapServiceConfig.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/CoordinateConverter.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/DeviceCapabilityRetry.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationProtocol.swift \
  ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift \
  ios-app/BikeComputerTests/NavigationProtocolTests.swift

"${OUT}"
