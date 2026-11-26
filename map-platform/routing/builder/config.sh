# shellcheck shell=bash
# shellcheck disable=SC2034  # the scripts that source this file use the variables
# Settings shared by the planet builder's scripts. Sourced, never run.
#
# Every path is absolute and derived from BICINO_SCRATCH. Run settings come
# from $BICINO_SCRATCH/builder.env, the file systemd also reads as the units'
# EnvironmentFile, so a stage behaves the same started by hand or by its unit.

BICINO_SCRATCH=${BICINO_SCRATCH:-/srv/bicino-routing-scratch}
case "$BICINO_SCRATCH" in
  /*) ;;
  *) echo "BICINO_SCRATCH must be an absolute path, got: $BICINO_SCRATCH" >&2; exit 64 ;;
esac
BICINO_SCRATCH=${BICINO_SCRATCH%/}

# builder.env holds plain KEY=value lines. Read it instead of sourcing it:
# systemd and bash then agree on every value, and it cannot run code.
bicino_load_env() {
  local file=$1 line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    if [[ "$line" != *=* || ! "$key" =~ ^BICINO_[A-Z0-9_]+$ || ! "$value" =~ ^[A-Za-z0-9_.:/@+,\ -]*$ ]]; then
      echo "$file: not a plain BICINO_KEY=value line: $line" >&2
      exit 64
    fi
    # The file wins over the caller's environment, as it does under systemd.
    printf -v "$key" '%s' "$value"
    # shellcheck disable=SC2163  # exports the variable named by $key
    export "$key"
  done < "$file"
}
bicino_load_env "$BICINO_SCRATCH/builder.env"

BICINO_REPO=$BICINO_SCRATCH/tools/repo
BICINO_ROUTING=$BICINO_REPO/map-platform/routing
BICINO_BUILDER=$BICINO_ROUTING/builder
BICINO_INPUT=$BICINO_SCRATCH/input
BICINO_BUILD=$BICINO_SCRATCH/build
BICINO_ELEVATION_RAW=$BICINO_SCRATCH/elevation-raw
# The graded build's tiles. With a terrain source these are the hybrid, and
# the opened Copernicus tiles and the terrain tiles it is made of lie beside it.
BICINO_ELEVATION=$BICINO_SCRATCH/elevation
BICINO_ELEVATION_OPENED=$BICINO_SCRATCH/elevation-opened
BICINO_ELEVATION_TERRAIN=$BICINO_SCRATCH/elevation-terrain
BICINO_AUDIT=$BICINO_SCRATCH/audit
BICINO_WORK=$BICINO_SCRATCH/work
# The VPS pulls from export/ with a read-only identity: markers, logs,
# evidence and the finished archives all live below it.
BICINO_EXPORT=$BICINO_SCRATCH/export
BICINO_CHAIN=$BICINO_EXPORT/chain
BICINO_LOGS=$BICINO_EXPORT/logs
BICINO_EVIDENCE=$BICINO_EXPORT/evidence

# The production API image of 2026-11-24. It supplies rasterio, Shapely and
# the backend's dependencies. Move it with BICINO_MAP_PLATFORM_IMAGE when the
# production image has moved; the result file records the one that ran.
BICINO_MAP_PLATFORM_IMAGE=${BICINO_MAP_PLATFORM_IMAGE:-ghcr.io/seichris/open-bike-computer-map-platform@sha256:249544826b4bc5e8733787bb5b03394240ed7d11e11fa073e3cacc86037d7ff7}
BICINO_PLATFORM=linux/amd64
BICINO_TOPOGRAPHY_POLICY=/app/map-platform/config/topography-source-policy-v2.json

# A c4-highmem-24-lssd has 24 vCPUs. The ungraded build starts while the
# elevation stage is still opening tiles, so it gets fewer threads.
BICINO_ELEVATION_JOBS=${BICINO_ELEVATION_JOBS:-20}
BICINO_UNGRADED_THREADS=${BICINO_UNGRADED_THREADS:-16}
BICINO_GRADED_THREADS=${BICINO_GRADED_THREADS:-20}
BICINO_ELEVATION_ATTEMPTS=${BICINO_ELEVATION_ATTEMPTS:-4}

# Empty builds only the ungraded planet, the graph production serves today.
BICINO_OPENING_RADIUS=${BICINO_OPENING_RADIUS:-}
# The id of the terrain source of elevation-sources.json to put over the
# opened tiles, such as usgs-3dep-13. Empty grades with opened Copernicus alone.
BICINO_TERRAIN=${BICINO_TERRAIN:-}
BICINO_PLANET_DATE=${BICINO_PLANET_DATE:-}
BICINO_TOOLS_COMMIT=${BICINO_TOOLS_COMMIT:-}

# A sample run rehearses the chain on one city of elevation-probes.json. It
# is never release evidence: the result file says so.
BICINO_SAMPLE_CITY=${BICINO_SAMPLE_CITY:-}
BICINO_SAMPLE_REGION_URL=${BICINO_SAMPLE_REGION_URL:-}

bicino_fail() {
  echo "error: $*" >&2
  exit 1
}

bicino_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

bicino_is_sample() {
  [ -n "$BICINO_SAMPLE_CITY" ]
}

bicino_is_graded() {
  [ -n "$BICINO_OPENING_RADIUS" ]
}

bicino_is_hybrid() {
  [ -n "$BICINO_TERRAIN" ]
}

bicino_validate_run() {
  [ -d "$BICINO_ROUTING" ] || bicino_fail "no routing tools at $BICINO_ROUTING"
  [[ "$BICINO_MAP_PLATFORM_IMAGE" =~ ^ghcr\.io/seichris/open-bike-computer-map-platform@sha256:[0-9a-f]{64}$ ]] \
    || bicino_fail "BICINO_MAP_PLATFORM_IMAGE must be pinned by digest"
  if [ -n "$BICINO_OPENING_RADIUS" ] && [[ ! "$BICINO_OPENING_RADIUS" =~ ^[0-9]{2,4}$ ]]; then
    bicino_fail "BICINO_OPENING_RADIUS must be whole metres or empty, got: $BICINO_OPENING_RADIUS"
  fi
  if bicino_is_hybrid; then
    [[ "$BICINO_TERRAIN" =~ ^[a-z][a-z0-9-]{2,63}$ ]] \
      || bicino_fail "BICINO_TERRAIN must be a terrain source id or empty, got: $BICINO_TERRAIN"
    bicino_is_graded || bicino_fail "BICINO_TERRAIN needs BICINO_OPENING_RADIUS: the terrain lies over opened tiles"
  fi
  local name
  for name in BICINO_ELEVATION_JOBS BICINO_UNGRADED_THREADS BICINO_GRADED_THREADS BICINO_ELEVATION_ATTEMPTS; do
    [[ "${!name}" =~ ^[1-9][0-9]?$ ]] || bicino_fail "$name must be a number from 1 to 99, got: ${!name}"
  done
  if bicino_is_sample; then
    [[ "$BICINO_SAMPLE_REGION_URL" =~ ^https://download\.geofabrik\.de/[a-z0-9/-]+\.osm\.pbf$ ]] \
      || bicino_fail "a sample needs BICINO_SAMPLE_REGION_URL, a Geofabrik extract"
  else
    [[ "$BICINO_PLANET_DATE" =~ ^[0-9]{6}$ ]] \
      || bicino_fail "BICINO_PLANET_DATE must be the planet snapshot's YYMMDD, got: $BICINO_PLANET_DATE"
  fi
}

# The OSM input every later stage reads, and where it came from.
bicino_source_url() {
  if bicino_is_sample; then
    echo "$BICINO_SAMPLE_REGION_URL"
  else
    echo "https://planet.openstreetmap.org/pbf/planet-$BICINO_PLANET_DATE.osm.pbf"
  fi
}

bicino_source_file() {
  local url
  url=$(bicino_source_url)
  echo "$BICINO_INPUT/${url##*/}"
}

# The graph builds read the sample's box, a planet build the whole download.
bicino_roads_file() {
  if bicino_is_sample; then
    echo "$BICINO_INPUT/sample/roads.osm.pbf"
  else
    bicino_source_file
  fi
}

bicino_graded_name() {
  if bicino_is_hybrid; then
    echo "$BICINO_TERRAIN-over-opened-$BICINO_OPENING_RADIUS"
  else
    echo "opened-$BICINO_OPENING_RADIUS"
  fi
}

# build_graph.py owns the Valhalla image pin; nothing here repeats it.
bicino_valhalla_image() {
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import build_graph; print(build_graph.IMAGE)' "$BICINO_ROUTING"
}

# Containers a killed stage left behind would block its next attempt.
bicino_remove_containers() {
  local label=$1 ids
  ids=$(docker ps -aq --filter "label=$label")
  if [ -n "$ids" ]; then
    echo "removing containers labelled $label"
    # shellcheck disable=SC2086  # one id per word
    docker rm -f $ids >/dev/null
  fi
}

# Waits until a Valhalla service answers /status, and fails if it never does.
# Runs in the map-platform image so the serving networks can stay internal.
bicino_wait_for_valhalla() {
  local network=$1 seconds=$2
  shift 2
  docker run --rm --init --platform "$BICINO_PLATFORM" --network "$network" \
    --label "bicino.stage=$BICINO_STAGE" --entrypoint python3 "$BICINO_MAP_PLATFORM_IMAGE" -c '
import sys, time, urllib.request
deadline = time.monotonic() + float(sys.argv[1])
for host in sys.argv[2:]:
    while True:
        try:
            urllib.request.urlopen(f"http://{host}:8002/status", timeout=5).read()
            print(f"{host} answers /status", flush=True)
            break
        except OSError as error:
            if time.monotonic() >= deadline:
                sys.exit(f"{host} did not answer /status within {sys.argv[1]} s: {error}")
            time.sleep(1)
' "$seconds" "$@"
}
