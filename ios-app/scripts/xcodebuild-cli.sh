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
exec "$xcodebuild_path" CC="$clang_wrapper" "$@"
