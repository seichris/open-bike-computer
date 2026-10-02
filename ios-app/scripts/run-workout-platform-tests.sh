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
cleanup() {
  if [[ "${OWNS_DERIVED_DATA}" -eq 1 ]]; then
    rm -rf "${DERIVED_DATA}"
  fi
}
trap cleanup EXIT

RESULT_BUNDLE_ARGS=()
if [[ -n "${DEV_CHECK_ARTIFACTS:-}" ]]; then
  mkdir -p "${DEV_CHECK_ARTIFACTS}"
  RESULT_DIR="$(mktemp -d "${DEV_CHECK_ARTIFACTS}/platform-${SCHEME}.XXXXXX")"
  RESULT_BUNDLE_ARGS=(-resultBundlePath "${RESULT_DIR}/tests.xcresult")
fi

cd "${IOS_APP_DIR}"
python3 "${IOS_APP_DIR}/../tools/development/simulator_session.py" --platform "$1" -- \
  "${SCRIPT_DIR}/xcodebuild-cli.sh" \
  -quiet \
  -project BikeComputer/BikeComputer.xcodeproj \
  -scheme "${SCHEME}" \
  -destination "id={simulator}" \
  -derivedDataPath "${DERIVED_DATA}" \
  "${RESULT_BUNDLE_ARGS[@]}" \
  CODE_SIGNING_ALLOWED=NO \
  ${ONLY_TESTING:+-only-testing:"${ONLY_TESTING}"} \
  test

echo "${SCHEME} passed"
