#!/bin/bash
# Write the raw Copernicus tiles, then open them at the run's radius. With
# terrain sources, also write their tiles and put them over the opened ones.
#
# With BICINO_ELEVATION_CACHE the raw tiles and, if the record keeps them, the
# tiles opened at this radius are first restored from the bucket. A restored
# set was checked tile by tile against the pinned record, and
# build_elevation.py then finds a receipt for every cell and builds none. A set
# that cannot be restored leaves its directory as it was and is built.
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

# hybrid and terrain hold the mounts and arguments of the terrain sources; manifests, what the run must leave.
hybrid=()
terrain=()
manifests=("$BICINO_ELEVATION_RAW/elevation-manifest.json" "$BICINO_ELEVATION/elevation-manifest.json")
directories=("$BICINO_ELEVATION_RAW" "$BICINO_ELEVATION")
if bicino_is_hybrid; then
  # bicino_validate_run has checked that the run names the list's sources.
  python3 - "$BICINO_ROUTING" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import build_elevation
for source in build_elevation.load_terrain_sources(Path(sys.argv[1]) / "elevation-sources.json"):
    print(f"terrain source {source.id}: {len(source.tiles)} cells, catalog {source.catalog_sha256}")
PY
  mkdir -p "$BICINO_ELEVATION_OPENED" "$BICINO_ELEVATION_TERRAIN"
  sha256sum "$BICINO_ROUTING/elevation-sources.json"
  hybrid=(-v "$BICINO_ELEVATION_OPENED:/opened" -v "$BICINO_ELEVATION_TERRAIN:/terrain")
  terrain=(--terrain-sources /routing/elevation-sources.json --terrain /terrain --opened /opened)
  if [ "$BICINO_TERRAIN_MIRROR_ENDPOINT" != none ]; then
    # The files a source keeps a copy of in a bucket are fetched first, so
    # that the build reads them from disk; a file that is not fetched, the
    # build reads from the source's origin. Fetched files stay for the next
    # attempt and run, and are checked again before they are used.
    mkdir -p "$BICINO_ELEVATION_TERRAIN_FILES"
    mirror=()
    if [ -n "$BICINO_TERRAIN_MIRROR_ENDPOINT" ]; then
      mirror=(--endpoint "$BICINO_TERRAIN_MIRROR_ENDPOINT")
    fi
    set +e
    python3 "$BICINO_BUILDER/elevation_cache.py" fetch-terrain --sources "$BICINO_ROUTING/elevation-sources.json" \
      --into "$BICINO_ELEVATION_TERRAIN_FILES" --jobs "$BICINO_ELEVATION_JOBS" ${mirror[@]+"${mirror[@]}"} \
      ${bounds[@]+"${bounds[@]}"}
    fetched=$?
    set -e
    echo "terrain files: fetch exit=$fetched"
    # A tile kept in the bucket alone has no origin: the build would fail its
    # cell after hours of others, so the stage stops now.
    [ "$fetched" -ne 4 ] || bicino_fail "terrain tiles kept only in gs://bicino-routing-elevation were not fetched (see above)"
    hybrid+=(-v "$BICINO_ELEVATION_TERRAIN_FILES:/terrain-files:ro")
    terrain+=(--terrain-files /terrain-files)
  fi
  manifests+=("$BICINO_ELEVATION_OPENED/elevation-manifest.json" "$BICINO_ELEVATION_TERRAIN/terrain-manifest.json")
  directories+=("$BICINO_ELEVATION_OPENED" "$BICINO_ELEVATION_TERRAIN")
fi

# What was restored, and why not, for the result file. A report of a run
# that asked for no record, or for another, is an earlier run's.
cache_report=$BICINO_EVIDENCE/elevation-cache.json
# What a killed restore assembled beside a directory. This run's restore takes
# up its own; the rest is nobody's and would only fill the scratch volume.
restoring=("$BICINO_ELEVATION_RAW.restoring" "$BICINO_ELEVATION.restoring" "$BICINO_ELEVATION_OPENED.restoring")
if bicino_uses_cache; then
  opened=$BICINO_ELEVATION
  if bicino_is_hybrid; then
    opened=$BICINO_ELEVATION_OPENED
  fi
  for left in "${restoring[@]}"; do
    if [ "$left" != "$BICINO_ELEVATION_RAW.restoring" ] && [ "$left" != "$opened.restoring" ]; then
      rm -rf "$left"
    fi
  done
  endpoint=()
  if [ -n "$BICINO_ELEVATION_CACHE_ENDPOINT" ]; then
    endpoint=(--endpoint "$BICINO_ELEVATION_CACHE_ENDPOINT")
  fi
  sha256sum "$BICINO_ROUTING/releases/$BICINO_ELEVATION_CACHE"
  set +e
  python3 "$BICINO_BUILDER/elevation_cache.py" restore \
    --record "$BICINO_ROUTING/releases/$BICINO_ELEVATION_CACHE" --report "$cache_report" \
    --jobs "$BICINO_ELEVATION_JOBS" ${endpoint[@]+"${endpoint[@]}"} \
    --set raw "$BICINO_ELEVATION_RAW" --set-if-kept "opened-$BICINO_OPENING_RADIUS" "$opened"
  restored=$?
  set -e
  if [ "$restored" -eq 0 ]; then
    echo "cache: every kept set is restored"
  else
    # Its directory is as it was, so the tiles are built as without a record.
    echo "cache: restore exit=$restored; building the tiles that were not restored"
  fi
else
  rm -f "$cache_report"
  rm -rf "${restoring[@]}"
fi

container=bicino-elevation-$BICINO_RUN_ID
status=1
for attempt in $(seq 1 "$BICINO_ELEVATION_ATTEMPTS"); do
  echo "attempt=$attempt start=$(bicino_now)"
  docker rm -f "$container" >/dev/null 2>&1 || true
  set +e
  docker run --rm --init --name "$container" --platform "$BICINO_PLATFORM" -u "$(id -u):$(id -g)" \
    --label "bicino.stage=$BICINO_STAGE@$BICINO_SCRATCH" \
    -v "$BICINO_ROUTING:/routing:ro" -v "$BICINO_ELEVATION_RAW:/raw" -v "$BICINO_ELEVATION:/out" \
    ${hybrid[@]+"${hybrid[@]}"} --entrypoint python3 "$BICINO_MAP_PLATFORM_IMAGE" \
    /routing/build_elevation.py --raw /raw --out /out --opening-radius "$BICINO_OPENING_RADIUS" \
    ${terrain[@]+"${terrain[@]}"} \
    --jobs "$BICINO_ELEVATION_JOBS" --policy "$BICINO_TOPOGRAPHY_POLICY" ${bounds[@]+"${bounds[@]}"} 2>&1 \
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

for manifest in "${manifests[@]}"; do
  [ -s "$manifest" ] || bicino_fail "no elevation manifest at $manifest"
  sha256sum "$manifest"
done
if bicino_uses_cache && [ -s "$cache_report" ]; then
  # Did the build leave the restored tiles as the record pins them?
  python3 "$BICINO_BUILDER/elevation_cache.py" compare --report "$cache_report"
fi
du -sb "${directories[@]}"
