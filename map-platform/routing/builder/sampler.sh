#!/bin/bash
# Every 30 seconds: the scratch volume's use and the host's memory, their
# peaks since the run began, and a heartbeat the status command can read.
set -uo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

mkdir -p "$BICINO_CHAIN" "$BICINO_LOGS"
state=$BICINO_CHAIN/sampler.json
peak_disk=0
peak_memory=0
if [ -s "$state" ]; then
  # A restarted sampler keeps the run's peaks.
  read -r peak_disk peak_memory < <(python3 -c '
import json, sys
try:
    saved = json.load(open(sys.argv[1]))
    print(int(saved["peakDiskBytes"]), int(saved["peakMemoryBytes"]))
except (OSError, ValueError, KeyError):
    print(0, 0)' "$state")
fi
while true; do
  now=$(bicino_now)
  disk=$(df --output=used -B1 "$BICINO_SCRATCH" | tail -1 | tr -d ' ')
  memory=$(free -b | awk '/^Mem:/ {print $3}')
  if [ "$disk" -gt "$peak_disk" ]; then peak_disk=$disk; fi
  if [ "$memory" -gt "$peak_memory" ]; then peak_memory=$memory; fi
  echo "$now $disk $memory" >> "$BICINO_LOGS/series.txt"
  printf '{"sampledAt": "%s", "diskUsedBytes": %s, "memoryUsedBytes": %s, "peakDiskBytes": %s, "peakMemoryBytes": %s}\n' \
    "$now" "$disk" "$memory" "$peak_disk" "$peak_memory" > "$state.partial"
  mv "$state.partial" "$state"
  sleep 30
done
