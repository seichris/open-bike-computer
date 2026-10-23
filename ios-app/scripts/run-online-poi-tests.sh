#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bicino-online-poi.XXXXXX")"
trap 'rm -rf "$RUN_TMP"' EXIT
python3 "$REPO_DIR/tools/development/swift_compile.py" online-poi -- \
  -parse-as-library -o "$RUN_TMP/online-poi-tests"
"$RUN_TMP/online-poi-tests"
