#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${IOS_DIR}/.." && pwd)"
WATCH_SDK_PATH="$(xcrun --sdk watchsimulator --show-sdk-path)"
ARCH="$(uname -m)"

case "${ARCH}" in
  arm64|x86_64) ;;
  *)
    echo "unsupported Watch Simulator host architecture: ${ARCH}" >&2
    exit 69
    ;;
esac

SDK_VERSION="$(xcrun --sdk watchsimulator --show-sdk-version)"
NATIVE_ZONE_FLAG=""
case "${SDK_VERSION}" in
  27|27.*) NATIVE_ZONE_FLAG="-DBICINO_HEALTHKIT_WORKOUT_ZONES" ;;
  *)
    echo "Native HealthKit zone adapter NOT checked: watchOS SDK ${SDK_VERSION} is not 27."
    if [[ "${REQUIRE_NATIVE_HEALTHKIT_ZONES:-0}" == 1 ]]; then exit 69; fi
    ;;
esac

cd "${REPO_DIR}"
find \
  ios-app/BikeComputer/BikeComputerWatch \
  ios-app/BikeComputer/RideShared \
  ios-app/BikeComputer/WorkoutShared \
  -type f -name '*.swift' -print0 | \
  xargs -0 xcrun swiftc \
    -typecheck \
    -parse-as-library \
    ${NATIVE_ZONE_FLAG:+"${NATIVE_ZONE_FLAG}"} \
    -target "${ARCH}-apple-watchos11.0-simulator" \
    -sdk "${WATCH_SDK_PATH}"

echo "Watch source graph type-check passed"
