#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
python3 "$ROOT/tools/development/swift_compile.py" diagnostics-broker-tests -- \
 -parse-as-library -o "$OUT/broker"
"$OUT/broker" "$@"
if [ "$#" -eq 0 ] && [ "$(uname)" = "Darwin" ]; then
 python3 "$ROOT/ios-app/tests/diagnostics-lifecycle-host/run.py"
fi
