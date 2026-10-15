#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
if command -v xcrun >/dev/null; then SWIFT=(xcrun swiftc); else SWIFT=(swiftc); fi
"${SWIFT[@]}" -parse-as-library -o "$OUT/policy" \
 "$ROOT/ios-app/BikeComputer/BikeComputer/Utilities/DiagnosticsSchema.generated.swift" \
 "$ROOT/ios-app/BikeComputer/BikeComputer/Utilities/DiagnosticsCapturePolicy.swift" \
 "$ROOT/ios-app/BikeComputerTests/DiagnosticsCapturePolicyTests.swift"
"$OUT/policy"
