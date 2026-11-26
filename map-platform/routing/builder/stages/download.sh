#!/bin/bash
# Download the OSM input and verify it against its published checksum.
#
# The transfer resumes, so a retry keeps what it has. The .sha256 file is
# written only after the published MD5 matched: later stages read it as proof
# that the download is the published file.
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
bicino_validate_run

url=$(bicino_source_url)
file=$(bicino_source_file)
name=${file##*/}
mkdir -p "$BICINO_INPUT"
rm -f "$file.sha256"
echo "source=$url"

remote_bytes=$(curl -fsSIL --retry 5 --retry-delay 5 "$url" | tr -d '\r' \
  | awk 'tolower($1) == "content-length:" {bytes = $2} END {print bytes}')
[[ "$remote_bytes" =~ ^[0-9]+$ ]] || bicino_fail "no Content-Length for $url"
local_bytes=0
if [ -f "$file" ]; then
  local_bytes=$(stat -c %s "$file")
fi
if [ "$local_bytes" -gt "$remote_bytes" ]; then
  echo "discarding $file: $local_bytes bytes, the source has $remote_bytes"
  rm -f "$file"
  local_bytes=0
fi
if [ "$local_bytes" -ne "$remote_bytes" ]; then
  echo "download start=$(bicino_now) have=$local_bytes of=$remote_bytes"
  curl -fL -sS -C - --retry 30 --retry-delay 10 --retry-all-errors -o "$file" "$url"
  echo "download end=$(bicino_now)"
fi

curl -fsSL --retry 5 --retry-delay 5 -o "$file.md5" "$url.md5"
listed=$(awk '{name = $2; sub(/^\*/, "", name); print name}' "$file.md5")
[ "$listed" = "$name" ] || bicino_fail "$url.md5 lists '$listed', not $name"
if ! (cd "$BICINO_INPUT" && md5sum -c "$name.md5"); then
  # A resumed transfer of a file that changed upstream cannot be repaired.
  rm -f "$file"
  bicino_fail "$name does not match its published MD5; it was removed, run the stage again"
fi
(cd "$BICINO_INPUT" && sha256sum "$name" > "$name.sha256.partial" && mv "$name.sha256.partial" "$name.sha256")
cat "$file.sha256"

if bicino_is_sample; then
  python3 "$BICINO_ROUTING/prepare_sample.py" --city "$BICINO_SAMPLE_CITY" --region "$file" \
    --region-url "$url" --out "$BICINO_INPUT/sample"
fi
