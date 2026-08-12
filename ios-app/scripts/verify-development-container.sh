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

require_file() {
  if [[ ! -s "$1" ]]; then
    echo "missing development-container file: $1" >&2
    exit 1
  fi
}

require_plist_value() {
  local plist_path="$1"
  local key_path="$2"
  local expected="$3"
  local actual
  if ! actual="$(/usr/libexec/PlistBuddy -c "Print ${key_path}" "${plist_path}")"; then
    echo "missing development-container plist value: ${plist_path} ${key_path}" >&2
    exit 1
  fi
  if [[ "${actual}" != "${expected}" ]]; then
    echo "invalid development-container plist value: ${plist_path} ${key_path}=${actual}" >&2
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
  echo "missing development-container URL scheme: ${plist_path} ${expected}" >&2
  exit 1
}

forbid_url_scheme() {
  local plist_path="$1"
  local forbidden="$2"
  local url_type_index=0
  local scheme_index
  local actual
  local actual_lower
  local forbidden_lower
  forbidden_lower="$(printf '%s' "${forbidden}" | tr '[:upper:]' '[:lower:]')"
  while /usr/libexec/PlistBuddy \
    -c "Print :CFBundleURLTypes:${url_type_index}" \
    "${plist_path}" >/dev/null 2>&1; do
    scheme_index=0
    while actual="$(/usr/libexec/PlistBuddy \
      -c "Print :CFBundleURLTypes:${url_type_index}:CFBundleURLSchemes:${scheme_index}" \
      "${plist_path}" 2>/dev/null)"; do
      actual_lower="$(printf '%s' "${actual}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${actual_lower}" == "${forbidden_lower}" ]]; then
        echo "forbidden development-container URL scheme: ${plist_path} ${forbidden}" >&2
        exit 1
      fi
      ((scheme_index += 1))
    done
    ((url_type_index += 1))
  done
}

require_file "${APP_PATH}/Info.plist"
require_file "${APP_PATH}/BikeComputer"
require_file "${WATCH_PATH}/Info.plist"
require_file "${WATCH_PATH}/BikeComputerWatch"
require_file "${COMPLICATION_PATH}/Info.plist"
require_file "${COMPLICATION_PATH}/BikeComputerWatchComplications"
require_file "${LIVE_ACTIVITY_PATH}/Info.plist"
require_file "${LIVE_ACTIVITY_PATH}/BikeComputerLiveActivity"

require_plist_value "${APP_PATH}/Info.plist" \
  ":CFBundleIdentifier" "LetItRide.BikeComputer.dev"
require_plist_value "${APP_PATH}/Info.plist" \
  ":CFBundleDisplayName" "Bicino Dev"
require_plist_value "${APP_PATH}/Info.plist" \
  ":CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName" "AppIconDev"

require_plist_value "${WATCH_PATH}/Info.plist" \
  ":CFBundleIdentifier" "LetItRide.BikeComputer.dev.watchkitapp"
require_plist_value "${WATCH_PATH}/Info.plist" \
  ":CFBundleDisplayName" "Bicino Dev"
require_plist_value "${WATCH_PATH}/Info.plist" \
  ":WKCompanionAppBundleIdentifier" "LetItRide.BikeComputer.dev"
require_plist_value "${WATCH_PATH}/Info.plist" \
  ":BicinoURLScheme" "bikecomputer-dev"
require_url_scheme "${WATCH_PATH}/Info.plist" "bikecomputer-dev"
forbid_url_scheme "${WATCH_PATH}/Info.plist" "bikecomputer"

require_plist_value "${COMPLICATION_PATH}/Info.plist" \
  ":CFBundleIdentifier" \
  "LetItRide.BikeComputer.dev.watchkitapp.complications"
require_plist_value "${COMPLICATION_PATH}/Info.plist" \
  ":CFBundleDisplayName" "Start Ride Dev"
require_plist_value "${COMPLICATION_PATH}/Info.plist" \
  ":BicinoURLScheme" "bikecomputer-dev"
require_plist_value "${COMPLICATION_PATH}/Info.plist" \
  ":NSExtension:NSExtensionPointIdentifier" "com.apple.widgetkit-extension"

require_plist_value "${LIVE_ACTIVITY_PATH}/Info.plist" \
  ":CFBundleIdentifier" \
  "LetItRide.BikeComputer.dev.WorkoutLiveActivity"
require_plist_value "${LIVE_ACTIVITY_PATH}/Info.plist" \
  ":CFBundleDisplayName" "Bicino Dev"
require_plist_value "${LIVE_ACTIVITY_PATH}/Info.plist" \
  ":NSExtension:NSExtensionPointIdentifier" "com.apple.widgetkit-extension"

echo "Development iPhone container, Watch app, complication, and Live Activity verified"
