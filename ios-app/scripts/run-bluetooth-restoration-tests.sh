#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bicino-ble-restoration.XXXXXX")"
trap 'rm -rf "$RUN_TMP"' EXIT
COMPILER="$ROOT/tools/development/swift_compile.py"
python3 "$COMPILER" bluetooth-restoration-corebluetooth-double -- \
  -swift-version 5 -emit-library -emit-module -module-name CoreBluetooth \
  -emit-module-path "$RUN_TMP/CoreBluetooth.swiftmodule" \
  -o "$RUN_TMP/libCoreBluetooth.dylib"
python3 "$COMPILER" navigation-5 -- \
  -D HOST_TESTING -D BLUETOOTH_RESTORATION_ADAPTER_TESTING \
  -I "$RUN_TMP" -L "$RUN_TMP" -lCoreBluetooth \
  -Xlinker -rpath -Xlinker "$RUN_TMP" -o "$RUN_TMP/tests"
"$RUN_TMP/tests" --bluetooth-restoration-adapter-only
