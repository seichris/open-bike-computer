#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <BikeComputer.app>" >&2
  exit 64
fi

APP_PATH="${1%/}"
WATCH_PATH="${APP_PATH}/Watch/BikeComputerWatch.app"
COMPLICATION_PATH="${WATCH_PATH}/PlugIns/BikeComputerWatchComplications.appex"
LIVE_ACTIVITY_PATH="${APP_PATH}/PlugIns/BikeComputerLiveActivity.appex"
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_file() {
  if [[ ! -s "$1" ]]; then
    echo "missing release-container file: $1" >&2
    exit 1
  fi
}

require_plist_value() {
  local plist_path="$1"
  local key_path="$2"
  local expected="$3"
  local actual
  if ! actual="$(/usr/libexec/PlistBuddy -c "Print ${key_path}" "${plist_path}")"; then
    echo "missing release-container plist value: ${plist_path} ${key_path}" >&2
    exit 1
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    echo "invalid release-container plist value: ${plist_path} ${key_path}=${actual}" >&2
    exit 1
  fi
}

require_url_scheme() {
  local plist_path="$1"
  local expected="$2"
  local url_type_index=0
  local scheme_index
  local actual
  while /usr/libexec/PlistBuddy \
    -c "Print :CFBundleURLTypes:${url_type_index}" \
    "${plist_path}" >/dev/null 2>&1; do
    scheme_index=0
    while actual="$(/usr/libexec/PlistBuddy \
      -c "Print :CFBundleURLTypes:${url_type_index}:CFBundleURLSchemes:${scheme_index}" \
      "${plist_path}" 2>/dev/null)"; do
      if [[ "${actual}" == "${expected}" ]]; then
        return
      fi
      ((scheme_index += 1))
    done
    ((url_type_index += 1))
  done
  echo "missing release-container URL scheme: ${plist_path} ${expected}" >&2
  exit 1
}

require_file "${APP_PATH}/Info.plist"
require_file "${APP_PATH}/BikeComputer"
require_file "${APP_PATH}/PrivacyInfo.xcprivacy"
require_file "${WATCH_PATH}/Info.plist"
require_file "${WATCH_PATH}/BikeComputerWatch"
require_file "${WATCH_PATH}/PrivacyInfo.xcprivacy"
require_file "${WATCH_PATH}/Assets.car"
require_file "${COMPLICATION_PATH}/Info.plist"
require_file "${COMPLICATION_PATH}/BikeComputerWatchComplications"
require_file "${LIVE_ACTIVITY_PATH}/Info.plist"
require_file "${LIVE_ACTIVITY_PATH}/BikeComputerLiveActivity"

cmp "${SOURCE_ROOT}/BikeComputer/BikeComputer/PrivacyInfo.xcprivacy" \
  "${APP_PATH}/PrivacyInfo.xcprivacy"
cmp "${SOURCE_ROOT}/BikeComputer/BikeComputerWatch/PrivacyInfo.xcprivacy" \
  "${WATCH_PATH}/PrivacyInfo.xcprivacy"

require_plist_value \
  "${APP_PATH}/Info.plist" \
  ":CFBundleIdentifier" \
  "LetItRide.BikeComputer"
require_plist_value \
  "${WATCH_PATH}/Info.plist" \
  ":CFBundleIdentifier" \
  "LetItRide.BikeComputer.watchkitapp"
require_plist_value \
  "${COMPLICATION_PATH}/Info.plist" \
  ":CFBundleIdentifier" \
  "LetItRide.BikeComputer.watchkitapp.complications"
require_plist_value \
  "${COMPLICATION_PATH}/Info.plist" \
  ":NSExtension:NSExtensionPointIdentifier" \
  "com.apple.widgetkit-extension"
require_plist_value \
  "${LIVE_ACTIVITY_PATH}/Info.plist" \
  ":CFBundleIdentifier" \
  "LetItRide.BikeComputer.WorkoutLiveActivity"
require_plist_value \
  "${LIVE_ACTIVITY_PATH}/Info.plist" \
  ":NSExtension:NSExtensionPointIdentifier" \
  "com.apple.widgetkit-extension"
require_plist_value \
  "${APP_PATH}/Info.plist" \
  ":NSSupportsLiveActivities" \
  "true"
require_url_scheme "${WATCH_PATH}/Info.plist" "bikecomputer"
WATCH_BACKGROUND_MODES="$(
  /usr/libexec/PlistBuddy -c 'Print :WKBackgroundModes' "${WATCH_PATH}/Info.plist"
)"
if [[ "${WATCH_BACKGROUND_MODES}" != *"workout-processing"* ]]; then
  echo "invalid Watch background modes: ${WATCH_BACKGROUND_MODES}" >&2
  exit 1
fi
WATCH_PRIMARY_ICON="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' \
    "${WATCH_PATH}/Info.plist"
)"
if [[ "${WATCH_PRIMARY_ICON}" != "AppIcon" ]]; then
  echo "invalid Watch primary icon metadata: ${WATCH_PRIMARY_ICON}" >&2
  exit 1
fi

echo "Release iPhone container, Watch app, complication, and Live Activity verified"
