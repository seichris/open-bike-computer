#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <ios|watchos>" >&2
  exit 64
fi

case "$1" in
  ios)
    RUNTIME_FRAGMENT=".iOS-"
    SCHEME="WorkoutContractiOSTests"
    ;;
  watchos)
    RUNTIME_FRAGMENT=".watchOS-"
    SCHEME="WorkoutContractWatchTests"
    ;;
  *)
    echo "unsupported platform: $1" >&2
    exit 64
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OWNS_DERIVED_DATA=0
if [[ -n "${CI_DERIVED_DATA_PATH:-}" ]]; then
  if [[ "${CI_DERIVED_DATA_PATH}" != /* || "${CI_DERIVED_DATA_PATH}" == "/" ]]; then
    echo "CI_DERIVED_DATA_PATH must be a non-root absolute path" >&2
    exit 64
  fi
  DERIVED_DATA="${CI_DERIVED_DATA_PATH}"
  if [[ -L "${DERIVED_DATA}" ]]; then
    echo "CI_DERIVED_DATA_PATH must not be a symlink" >&2
    exit 64
  fi
  mkdir -p "${DERIVED_DATA}"
else
  DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/open-bike-${SCHEME}.XXXXXX")"
  OWNS_DERIVED_DATA=1
fi
SIMULATOR_BOOTED_BY_SCRIPT=0

cleanup() {
  if [[ "${SIMULATOR_BOOTED_BY_SCRIPT}" -eq 1 && -n "${SIMULATOR_UDID:-}" ]]; then
    xcrun simctl shutdown "${SIMULATOR_UDID}" 2>/dev/null || true
  fi
  if [[ "${OWNS_DERIVED_DATA}" -eq 1 ]]; then
    rm -rf "${DERIVED_DATA}"
  fi
}
trap cleanup EXIT

SIMULATOR_SELECTION="$(/usr/bin/python3 - "${RUNTIME_FRAGMENT}" <<'PY'
import json
import subprocess
import sys

runtime_fragment = sys.argv[1]
payload = json.loads(
    subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        text=True,
    )
)

def runtime_version(identifier):
    suffix = identifier.rsplit(".", 1)[-1].split("-", 1)[-1]
    return tuple(int(component) for component in suffix.split("-") if component.isdigit())

for runtime, devices in sorted(
    payload["devices"].items(),
    key=lambda item: runtime_version(item[0]),
    reverse=True,
):
    if runtime_fragment not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable", False):
            print(f'{device["udid"]}\t{device.get("state", "Shutdown")}')
            raise SystemExit(0)
raise SystemExit(1)
PY
)" || {
  echo "no available $1 simulator is installed" >&2
  exit 69
}

IFS=$'\t' read -r SIMULATOR_UDID SIMULATOR_STATE <<< "${SIMULATOR_SELECTION}"
if [[ "${SIMULATOR_STATE}" != "Booted" ]]; then
  xcrun simctl boot "${SIMULATOR_UDID}"
  SIMULATOR_BOOTED_BY_SCRIPT=1
fi
xcrun simctl bootstatus "${SIMULATOR_UDID}" -b

cd "${IOS_APP_DIR}"
"${SCRIPT_DIR}/xcodebuild-cli.sh" \
  -quiet \
  -project BikeComputer/BikeComputer.xcodeproj \
  -scheme "${SCHEME}" \
  -destination "id=${SIMULATOR_UDID}" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  ${ONLY_TESTING:+-only-testing:"${ONLY_TESTING}"} \
  test

echo "${SCHEME} passed"
