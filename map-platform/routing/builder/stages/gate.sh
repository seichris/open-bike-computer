#!/bin/bash
# Serve the ungraded and the graded archive privately and run the elevation gate.
#
# compare_elevation.py routes every city of elevation-probes.json on both
# graphs. A source that misses a target is the gate's answer, not a failed
# stage: the stage fails only when the comparison could not be made.
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
bicino_validate_run
bicino_is_graded || bicino_fail "the gate needs a graded build"

network=bicino-gate
source_name=$(bicino_graded_name)
out=$BICINO_EVIDENCE/gate
valhalla_image=$(bicino_valhalla_image)
for label in ungraded graded; do
  [ -s "$BICINO_BUILD/planet-$label/manifest.json" ] || bicino_fail "no finished $label build"
done
mkdir -p "$out"
rm -f "$out/gate-report.json" "$out/gate-summary.json" "$out/gate-summary.md"

cleanup() {
  bicino_remove_containers "bicino.stage=$BICINO_STAGE" || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
docker network create --internal "$network" >/dev/null

# serve NAME ARCHIVE [ELEVATION]: a graded graph's tiles are mounted for /height.
serve() {
  local name=$1 archive=$2 elevation=${3:-} options=() flags=""
  if [ -n "$elevation" ]; then
    options=(-v "$elevation:/elevation:ro")
    flags="--additional-data-elevation /elevation"
  fi
  docker run -d --init --name "$name" --network "$network" --platform "$BICINO_PLATFORM" --cpus 4 --memory 8g \
    --read-only --tmpfs /tmp:size=64m --label "bicino.stage=$BICINO_STAGE" \
    -v "$archive:/graph/valhalla_tiles.tar:ro" "${options[@]}" --entrypoint /bin/bash "$valhalla_image" -ec "
      valhalla_build_config --mjolnir-tile-extract /graph/valhalla_tiles.tar $flags > /tmp/valhalla.json
      exec valhalla_service /tmp/valhalla.json 4" >/dev/null
}
serve bicino-gate-ungraded "$BICINO_BUILD/planet-ungraded/valhalla_tiles.tar"
serve bicino-gate-graded "$BICINO_BUILD/planet-graded/valhalla_tiles.tar" "$BICINO_ELEVATION"
bicino_wait_for_valhalla "$network" 300 bicino-gate-ungraded bicino-gate-graded

cities=()
if bicino_is_sample; then
  cities=(--city "$BICINO_SAMPLE_CITY")
fi
# in_gate COMMAND...: the map-platform image on the gate's network; -i passes a script on stdin.
in_gate() {
  docker run --rm --init -i --network "$network" --platform "$BICINO_PLATFORM" -u "$(id -u):$(id -g)" \
    --label "bicino.stage=$BICINO_STAGE" -v "$BICINO_REPO/map-platform:/mp:ro" -v "$out:/out" \
    --entrypoint python3 "$BICINO_MAP_PLATFORM_IMAGE" "$@"
}

# The graded service must answer /height from its tiles and the ungraded one
# must not: a gate between two services wired the wrong way would pass.
in_gate - "${BICINO_SAMPLE_CITY:-}" <<'PY'
import json, sys, urllib.request
cities = json.load(open("/mp/routing/elevation-probes.json"))
city = next(city for city in cities if city["city"] == sys.argv[1]) if sys.argv[1] else cities[0]
leg = city["legs"][0]
shape = [{"lat": lat, "lon": lon} for lat, lon in (leg["origin"], leg["destination"])]
body = json.dumps({"shape": shape, "range": False}).encode()
heights = {}
for host in ("bicino-gate-graded", "bicino-gate-ungraded"):
    request = urllib.request.Request(f"http://{host}:8002/height", body, {"Content-Type": "application/json"})
    heights[host] = json.load(urllib.request.urlopen(request, timeout=30)).get("height")
    print(host, "/height", city["city"], heights[host], flush=True)
if any(height is None for height in heights["bicino-gate-graded"]):
    sys.exit("the graded service has no heights: its elevation tiles are not mounted")
if any(height is not None for height in heights["bicino-gate-ungraded"]):
    sys.exit("the ungraded service returns heights: the two services are swapped")
PY

echo "run start=$(bicino_now)"
in_gate /mp/routing/compare_elevation.py run "${cities[@]}" \
  --ungraded http://bicino-gate-ungraded:8002 --graded "$source_name=http://bicino-gate-graded:8002" \
  --out /out/gate-report.json
echo "run end=$(bicino_now)"

set +e
in_gate /mp/routing/compare_elevation.py summary /out/gate-report.json --json /out/gate-summary.json \
  > "$out/gate-summary.md"
status=$?
set -e
cat "$out/gate-summary.md"
echo "summary exit=$status"
# 0 meets the targets and 1 misses them; both leave the summary. Anything
# else, or no summary, means the gate did not run.
python3 - "$out/gate-summary.json" "$status" <<'PY'
import json, sys
failures = json.load(open(sys.argv[1]))["failures"]
missed = any(failures.values())
if int(sys.argv[2]) != (1 if missed else 0):
    sys.exit(f"summary exited {sys.argv[2]} but its report says missed={missed}")
print("gate verdict:", "missed" if missed else "met")
PY
