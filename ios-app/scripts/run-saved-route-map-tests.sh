#!/usr/bin/env bash
set -euo pipefail

DEV_SWIFT_COMPILER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/development/swift_compile.py"

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

python3 "${DEV_SWIFT_COMPILER}" saved-route-map-1 -- \
  -parse-as-library -o "${OUT_DIR}/policy"
"${OUT_DIR}/policy"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Native saved-route map integration tests skipped: macOS and an Apple SDK are required."
  exit 0
fi

MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_SUPPORT="${MACOS_SDK}/System/iOSSupport"
python3 "${DEV_SWIFT_COMPILER}" saved-route-map-2 -- \
  -D HOST_TESTING -parse-as-library \
  -target "$(uname -m)-apple-ios16.4-macabi" \
  -sdk "${MACOS_SDK}" \
  -F "${IOS_SUPPORT}/System/Library/Frameworks" \
  -I "${IOS_SUPPORT}/usr/lib/swift" \
  -L "${IOS_SUPPORT}/usr/lib/swift" \
  -o "${OUT_DIR}/integration"
"${OUT_DIR}/integration"
