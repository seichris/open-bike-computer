#!/usr/bin/env bash

set -euo pipefail

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
real_clang="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

if [[ ! -x "$real_clang" ]]; then
    echo "Apple clang not found at $real_clang" >&2
    exit 69
fi

has_preprocess=false
has_macro_dump=false
has_null_input=false

for arg in "$@"; do
    case "$arg" in
        -E)
            has_preprocess=true
            ;;
        -dM)
            has_macro_dump=true
            ;;
        /dev/null)
            has_null_input=true
            ;;
    esac
done

# Xcode 26.6's build service has been observed deadlocking while capturing the
# verbose output from its compiler-discovery probe. Removing only -v keeps the
# macro output Xcode consumes while avoiding the blocked stderr pipe. Real
# compilation and linking invocations are forwarded byte-for-byte to Apple clang.
if $has_preprocess && $has_macro_dump && $has_null_input; then
    filtered_args=()
    for arg in "$@"; do
        if [[ "$arg" != "-v" ]]; then
            filtered_args+=("$arg")
        fi
    done
    exec "$real_clang" "${filtered_args[@]}"
fi

exec "$real_clang" "$@"
