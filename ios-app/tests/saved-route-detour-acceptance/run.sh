#!/usr/bin/env bash
# Live saved-route detour acceptance (development only). Builds the harness
# from the shared app sources, rides the Dubai GPX route, leaves it, and
# requires: live MapKit cycling → no cycling route (UAE) → authenticated
# Bicino /v1/bicycle-detours (Valhalla bicycle) → detour → confirmed rejoin →
# original guidance resumed. Needs BICINO_SERVICE_URL, BICINO_INSTALLATION_ID
# and BICINO_INSTALLATION_TOKEN; the token is never printed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/saved-route-detour-acceptance.XXXXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT
cd "${REPO_DIR}"
python3 tools/development/swift_compile.py saved-route-detour-acceptance -- \
  -swift-version 6 -default-isolation MainActor -o "${OUT_DIR}/acceptance"
"${OUT_DIR}/acceptance" "${GPX:-${SCRIPT_DIR}/dubai-detour-acceptance.gpx}" "${EVIDENCE:-${OUT_DIR}/evidence.json}"
