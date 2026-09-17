#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/../.."
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/world-radio-tests.XXXXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT
if command -v xcrun >/dev/null 2>&1; then
  compiler=(xcrun swiftc)
else
  compiler=(swiftc)
fi
python3 tools/generate_ride_ble_contract.py --check
python3 -m unittest esp32.tools.tests.test_world_radio_contract_reuse
"${compiler[@]}" -swift-version 6 -strict-concurrency=complete \
  -default-isolation MainActor -D HOST_TESTING -o "${OUT_DIR}/tests" \
  ios-app/BikeComputer/BikeComputer/Models/WorldRadioProtocol.swift \
  ios-app/BikeComputer/BikeComputer/Services/WorldRadioService.swift \
  ios-app/BikeComputer/RideShared/RideBLEProtocol.generated.swift \
  ios-app/BikeComputer/RideShared/WireBytes.swift \
  ios-app/BikeComputerTests/WorldRadioTests.swift
"${OUT_DIR}/tests"
