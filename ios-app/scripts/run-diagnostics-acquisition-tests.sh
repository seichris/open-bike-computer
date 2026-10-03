#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
if command -v xcrun >/dev/null; then SWIFT=(xcrun swiftc); else SWIFT=(swiftc); fi
"${SWIFT[@]}" -parse-as-library -o "$OUT/acquisitions" \
 "$ROOT/ios-app/BikeComputer/BikeComputer/Managers/DiagnosticsAcquisitionStore.swift" \
 "$ROOT/ios-app/BikeComputerTests/DiagnosticsAcquisitionStoreTests.swift"
"$OUT/acquisitions"
