#!/usr/bin/env bash
set -euo pipefail

DEV_SWIFT_COMPILER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/development/swift_compile.py"

RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bicino-swift-check.XXXXXX")"
trap 'rm -rf "$RUN_TMP"' EXIT
export TMPDIR="${RUN_TMP}/"

"$(dirname "${BASH_SOURCE[0]}")/run-device-map-operation-tests.sh"

"$(dirname "${BASH_SOURCE[0]}")/run-native-workout-zone-tests.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${IOS_DIR}/.." && pwd)"
OUT="${TMPDIR:-/tmp}/open-bike-navigation-tests"

cd "${REPO_DIR}"

python3 "${SCRIPT_DIR}/run-durable-map-attempt-tests.py"
python3 "${SCRIPT_DIR}/run-map-upload-binding-tests.py"

TOPOGRAPHY_ALIGNMENT_OUT="${TMPDIR:-/tmp}/open-bike-topography-alignment-tests"
python3 "${DEV_SWIFT_COMPILER}" navigation-1 -- \
  -parse-as-library \
  -o "${TOPOGRAPHY_ALIGNMENT_OUT}"
"${TOPOGRAPHY_ALIGNMENT_OUT}"

"${SCRIPT_DIR}/run-device-operation-tests.sh"
"${SCRIPT_DIR}/run-cycling-sensor-observation-tests.sh"
bash "${SCRIPT_DIR}/run-saved-route-map-tests.sh"
bash "${SCRIPT_DIR}/run-offline-route-tests.sh"

RENDERER_SCHEDULER_OUT="${TMPDIR:-/tmp}/open-bike-renderer-scheduler-tests"
python3 "${DEV_SWIFT_COMPILER}" navigation-2 -- \
  -D HOST_TESTING -parse-as-library \
  -o "${RENDERER_SCHEDULER_OUT}"
"${RENDERER_SCHEDULER_OUT}"

RENDERER_WINDOW_OUT="${TMPDIR:-/tmp}/open-bike-renderer-window-tests"
python3 "${DEV_SWIFT_COMPILER}" navigation-3 -- \
  -D HOST_TESTING -parse-as-library \
  -o "${RENDERER_WINDOW_OUT}"
"${RENDERER_WINDOW_OUT}"

RENDERER_DELIVERY_OUT="${TMPDIR:-/tmp}/open-bike-renderer-delivery-tests"
python3 "${DEV_SWIFT_COMPILER}" navigation-4 -- \
  -D HOST_TESTING -parse-as-library \
  -o "${RENDERER_DELIVERY_OUT}"
"${RENDERER_DELIVERY_OUT}"

python3 "${DEV_SWIFT_COMPILER}" navigation-5 -- \
  -D HOST_TESTING \
  -o "${OUT}"

"${OUT}"

bash "${SCRIPT_DIR}/run-world-radio-tests.sh"

CYCLING_SENSOR_OUT="${TMPDIR:-/tmp}/open-bike-cycling-sensor-tests"

for CYCLING_SENSOR_TEST in CyclingSensorTests CyclingSensorObservationIntegrationTests; do
python3 "${DEV_SWIFT_COMPILER}" navigation-6 -- \
  -parse-as-library \
  -default-isolation MainActor \
  -o "${CYCLING_SENSOR_OUT}" \
  "ios-app/BikeComputerTests/${CYCLING_SENSOR_TEST}.swift"

"${CYCLING_SENSOR_OUT}"
done

CATALYST_OUT="${TMPDIR:-/tmp}/open-bike-destination-callout-tests"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_SUPPORT="${MACOS_SDK}/System/iOSSupport"

python3 "${DEV_SWIFT_COMPILER}" navigation-7 -- \
  -D HOST_TESTING \
  -parse-as-library \
  -target "$(uname -m)-apple-ios16.4-macabi" \
  -sdk "${MACOS_SDK}" \
  -F "${IOS_SUPPORT}/System/Library/Frameworks" \
  -I "${IOS_SUPPORT}/usr/lib/swift" \
  -L "${IOS_SUPPORT}/usr/lib/swift" \
  -o "${CATALYST_OUT}"

"${CATALYST_OUT}"

MAP_APPEARANCE_CATALYST_OUT="${TMPDIR:-/tmp}/open-bike-map-appearance-tests"

python3 "${DEV_SWIFT_COMPILER}" navigation-8 -- \
  -D HOST_TESTING \
  -parse-as-library \
  -target "$(uname -m)-apple-ios16.4-macabi" \
  -sdk "${MACOS_SDK}" \
  -F "${IOS_SUPPORT}/System/Library/Frameworks" \
  -I "${IOS_SUPPORT}/usr/lib/swift" \
  -L "${IOS_SUPPORT}/usr/lib/swift" \
  -o "${MAP_APPEARANCE_CATALYST_OUT}"

"${MAP_APPEARANCE_CATALYST_OUT}"

PREVIEW_CATALYST_OUT="${TMPDIR:-/tmp}/open-bike-saved-map-preview-tests"

python3 "${DEV_SWIFT_COMPILER}" navigation-9 -- \
  -D HOST_TESTING \
  -parse-as-library \
  -target "$(uname -m)-apple-ios16.4-macabi" \
  -sdk "${MACOS_SDK}" \
  -F "${IOS_SUPPORT}/System/Library/Frameworks" \
  -I "${IOS_SUPPORT}/usr/lib/swift" \
  -L "${IOS_SUPPORT}/usr/lib/swift" \
  -o "${PREVIEW_CATALYST_OUT}"

"${PREVIEW_CATALYST_OUT}"
