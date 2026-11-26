#!/bin/bash
# Write the raw Copernicus tiles, then open them at the run's radius.
#
# build_elevation.py resumes from its receipts. It stops when the third round
# of one run still loses a worker to the 15-minute cell deadline, which
# happened on 2026-11-25; the same command then finishes the cells that are
# left. So the command is run again, a few times, before the stage fails.
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
bicino_validate_run
bicino_is_graded || bicino_fail "the elevation stage needs BICINO_OPENING_RADIUS"

bounds=()
if bicino_is_sample; then
  # From the city's box, not from the download stage's output: this stage
  # does not wait for the download.
  read -r -a bounds < <(python3 - "$BICINO_ROUTING" "$BICINO_SAMPLE_CITY" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import prepare_sample
cities = json.loads((Path(sys.argv[1]) / "elevation-probes.json").read_text())
print(*prepare_sample.elevation_bounds(prepare_sample.find_city(cities, sys.argv[2])["bbox"]))
PY
  )
  [ "${#bounds[@]}" -eq 4 ] || bicino_fail "no elevation bounds for the sample city $BICINO_SAMPLE_CITY"
  bounds=(--bounds "${bounds[@]}")
fi
mkdir -p "$BICINO_ELEVATION_RAW" "$BICINO_ELEVATION"
sha256sum "$BICINO_ROUTING/build_elevation.py"

status=1
for attempt in $(seq 1 "$BICINO_ELEVATION_ATTEMPTS"); do
  echo "attempt=$attempt start=$(bicino_now)"
  docker rm -f bicino-elevation >/dev/null 2>&1 || true
  set +e
  docker run --rm --init --name bicino-elevation --platform "$BICINO_PLATFORM" -u "$(id -u):$(id -g)" \
    --label "bicino.stage=$BICINO_STAGE" \
    -v "$BICINO_ROUTING:/routing:ro" -v "$BICINO_ELEVATION_RAW:/raw" -v "$BICINO_ELEVATION:/out" \
    --entrypoint python3 "$BICINO_MAP_PLATFORM_IMAGE" \
    /routing/build_elevation.py --raw /raw --out /out --opening-radius "$BICINO_OPENING_RADIUS" \
    --jobs "$BICINO_ELEVATION_JOBS" --policy "$BICINO_TOPOGRAPHY_POLICY" "${bounds[@]}" 2>&1 \
    | while IFS= read -r line; do printf '%s %s\n' "$(bicino_now)" "$line"; done
  status=${PIPESTATUS[0]}
  set -e
  echo "attempt=$attempt exit=$status end=$(bicino_now)"
  if [ "$status" -eq 0 ]; then
    break
  fi
  # A failure that is not about cells (no image, no network) is not hurried.
  sleep 30
done
[ "$status" -eq 0 ] || bicino_fail "build_elevation.py failed $BICINO_ELEVATION_ATTEMPTS times"

for manifest in "$BICINO_ELEVATION_RAW/elevation-manifest.json" "$BICINO_ELEVATION/elevation-manifest.json"; do
  [ -s "$manifest" ] || bicino_fail "no elevation manifest at $manifest"
  sha256sum "$manifest"
done
du -sb "$BICINO_ELEVATION_RAW" "$BICINO_ELEVATION"
