#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
xcodebuild_path="${XCODEBUILD_PATH:-$(xcrun --find xcodebuild)}"
clang_wrapper="$script_dir/xcode-clang-wrapper.sh"

if [[ ! -x "$clang_wrapper" ]]; then
    echo "Clang wrapper is not executable: $clang_wrapper" >&2
    exit 69
fi

# CC is a build-setting override. Callers can still replace it by passing a
# later CC=/path argument explicitly.
# Capture symbols only for explicit, unsigned/signed device app builds. Simulator
# contract runners keep their own resource lifecycle and do not enter this path.
configuration="Debug"
derived=""
scheme=""
action=""
args=("$@")
for ((index=0; index<${#args[@]}; index++)); do
    case "${args[index]}" in
        -configuration) configuration="${args[index+1]}" ;;
        -derivedDataPath) derived="${args[index+1]}" ;;
        -scheme) scheme="${args[index+1]}" ;;
        build) action="build" ;;
    esac
done
evidence="$script_dir/../../tools/build_evidence.py"
if [[ "$scheme" == BikeComputer && "$action" == build && -n "$derived" &&
      ( "${BICINO_COLLECT_BUILD_EVIDENCE:-0}" == 1 || "${BICINO_REQUIRE_BUILD_EVIDENCE:-0}" == 1 ) ]]; then
    before="$(python3 "$evidence" source)"
    if ! python3 -c 'import json,sys; sys.exit(bool(json.loads(sys.argv[1])["dirty"]))' "$before"; then
        echo 'Exact-build evidence requires clean committed source; use an ordinary build for local edits.' >&2
        exit 1
    fi
    "$xcodebuild_path" CC="$clang_wrapper" DEBUG_INFORMATION_FORMAT=dwarf-with-dsym "$@"
    if ! python3 "$evidence" ios --derived-data "$derived" \
        --configuration "$configuration" --source-before "$before"; then
        echo 'Build succeeded; exact-build symbol retention is blocked (see reason above).' >&2
        if [[ "${BICINO_REQUIRE_BUILD_EVIDENCE:-0}" == 1 ]]; then exit 1; fi
    fi
else
    exec "$xcodebuild_path" CC="$clang_wrapper" "$@"
fi
