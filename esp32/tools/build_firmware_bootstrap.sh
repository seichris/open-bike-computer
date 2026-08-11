#!/bin/sh
# Recovery entry point for hosts without a usable python3. Keep these two
# target records byte-for-byte aligned with firmware-runtime/lock-v1.json.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
system=$(uname -s)
machine=$(uname -m)

case "$system:$machine" in
  Darwin:arm64)
    target=macos-arm64-cp313
    archive_size=25307899
    archive_sha=ebcf53fe921c356ad2eecfcea370cb744e7bd96fdef41a53e1e8f32a15c6dfeb
    archive_url=https://github.com/astral-sh/python-build-standalone/releases/download/20260807/cpython-3.13.15%2B20260807-aarch64-apple-darwin-install_only.tar.gz
    ;;
  Linux:x86_64)
    target=linux-x86_64-cp313
    archive_size=119851095
    archive_sha=7253808c3413d9ebd03e76b3853c895b9287f12e0750a30fce1cbf430e516113
    archive_url=https://github.com/astral-sh/python-build-standalone/releases/download/20260807/cpython-3.13.15%2B20260807-x86_64-unknown-linux-gnu-install_only.tar.gz
    ;;
  *)
    echo "Unsupported firmware recovery host: $system $machine" >&2
    exit 1
    ;;
esac

recovery_root=$project_dir/.pio/open-bike-build/recovery-python
target_root=$recovery_root/$target
archive=$target_root/$archive_sha.tar.gz
staging=

cleanup() {
  if [ -n "$staging" ]; then
    case "$staging" in
      "$target_root"/.recovery.*)
        chmod -R u+w "$staging" 2>/dev/null || true
        rm -rf -- "$staging"
        ;;
      *)
        echo "Refusing to clean unexpected recovery staging path: $staging" >&2
        ;;
    esac
  fi
}
trap cleanup EXIT HUP INT TERM

for checked in "$project_dir/.pio" "$project_dir/.pio/open-bike-build" "$recovery_root" "$target_root"; do
  if [ -L "$checked" ]; then
    echo "Refusing recovery through symlink: $checked" >&2
    exit 1
  fi
done
mkdir -p "$target_root"

verify_archive() {
  [ -f "$archive" ] && [ ! -L "$archive" ] || return 1
  actual_size=$(wc -c < "$archive" | tr -d ' ')
  [ "$actual_size" = "$archive_size" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    actual_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    actual_sha=$(sha256sum "$archive" | awk '{print $1}')
  else
    echo "Recovery requires shasum or sha256sum" >&2
    exit 1
  fi
  [ "$actual_sha" = "$archive_sha" ]
}

if ! verify_archive; then
  partial=$target_root/.$archive_sha.download
  if [ -e "$partial" ] || [ -L "$partial" ]; then
    echo "Refusing to replace unexpected recovery partial: $partial" >&2
    exit 1
  fi
  curl --fail --location --proto '=https' --tlsv1.2 --output "$partial" "$archive_url"
  mv "$partial" "$archive"
  if ! verify_archive; then
    echo "Downloaded recovery Python did not match the tracked size and SHA-256" >&2
    exit 1
  fi
fi

staging=$(mktemp -d "$target_root/.recovery.XXXXXX")
tar -xzf "$archive" -C "$staging"
if [ ! -x "$staging/python/bin/python3" ]; then
  echo "Tracked recovery archive has no expected Python executable" >&2
  exit 1
fi

# Never reuse an extracted recovery interpreter: the verified archive is the
# trust anchor, and a fresh project-private extraction prevents persisted
# mutation from becoming executable on a later repair invocation. The child
# re-execs into the accepted runtime; this shell then removes only its owned
# staging directory.
if [ "${OPEN_BIKE_FIRMWARE_RUNTIME_CACHE+x}" = x ]; then
  env -i PATH=/usr/bin:/bin \
    OPEN_BIKE_FIRMWARE_RUNTIME_CACHE="$OPEN_BIKE_FIRMWARE_RUNTIME_CACHE" \
    "$staging/python/bin/python3" "$script_dir/build_firmware.py" "$@"
else
  env -i PATH=/usr/bin:/bin \
    "$staging/python/bin/python3" "$script_dir/build_firmware.py" "$@"
fi
