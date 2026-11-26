#!/bin/bash
# Qualify one archive with no network: qualify.sh ungraded | graded.
#
# Smoke probes, cross-border probes, the territory audit and the profile
# probe all run, whatever the earlier ones found, so one stage leaves all the
# evidence. qualification.py then judges them and fails the stage if any
# check failed.
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
bicino_validate_run

label=${1:-}
case "$label" in
  ungraded|graded) ;;
  *) bicino_fail "usage: qualify.sh ungraded|graded" ;;
esac
archive=$BICINO_BUILD/planet-$label/valhalla_tiles.tar
[ -s "$BICINO_BUILD/planet-$label/manifest.json" ] || bicino_fail "no finished build in $BICINO_BUILD/planet-$label"
out=$BICINO_EVIDENCE/qualify-$label
mkdir -p "$out"
: > "$out/exit-codes.txt"
valhalla_image=$(bicino_valhalla_image)

# Inside the Valhalla image: serve the archive, wait for it, run the probe.
# shellcheck disable=SC2016  # expanded by the container's shell, not this one
serve_then_run='
valhalla_build_config --mjolnir-tile-extract /graph/valhalla_tiles.tar > /tmp/valhalla.json
valhalla_service /tmp/valhalla.json "$1" > /tmp/service.log 2>&1 &
for second in $(seq 1 300); do
  if python3 -c "import urllib.request; urllib.request.urlopen(\"http://127.0.0.1:8002/status\", timeout=5)" 2>/dev/null; then
    break
  fi
  if [ "$second" -eq 300 ]; then
    echo "valhalla_service did not answer /status within 300 s" >&2
    tail -20 /tmp/service.log >&2
    exit 70
  fi
  sleep 1
done
shift
exec "$@"'

# offline_check NAME CPUS MEMORY [docker run option]... -- COMMAND...
offline_check() {
  local name=$1 cpus=$2 memory=$3 options=() status
  shift 3
  while [ "$1" != -- ]; do
    options+=("$1")
    shift
  done
  shift
  echo "== $name start=$(bicino_now)"
  set +e
  docker run --rm --init --network none --platform "$BICINO_PLATFORM" --cpus "$cpus" --memory "$memory" \
    --read-only --tmpfs /tmp:size=64m --label "bicino.stage=$BICINO_STAGE" \
    -v "$archive:/graph/valhalla_tiles.tar:ro" -v "$BICINO_ROUTING:/probe:ro" "${options[@]}" \
    --entrypoint /bin/bash "$valhalla_image" -ec "$serve_then_run" _ "$cpus" "$@" \
    > "$out/$name.json" 2> "$out/$name.err"
  status=$?
  set -e
  echo "$name $status" >> "$out/exit-codes.txt"
  echo "== $name exit=$status end=$(bicino_now)"
}

if bicino_is_sample; then
  offline_check smoke 2 2g -v "$BICINO_INPUT/sample:/sample:ro" -- \
    python3 /probe/probe_graph.py --coverage planet --concurrency 4 --probes /sample/probes.json
  python3 "$BICINO_BUILDER/qualification.py" --dir "$out" --label "$label" --sample
  exit 0
fi

offline_check smoke 2 2g -- \
  python3 /probe/probe_graph.py --coverage planet --concurrency 4 --probes /probe/probes.json
offline_check cross-border 2 2g -- \
  python3 /probe/probe_graph.py --coverage planet --concurrency 4 --probes /probe/cross-border-probes.json
offline_check audit 4 8g -v "$BICINO_AUDIT/inventory-all-units.json:/inventory.json:ro" -- \
  python3 /probe/coverage_audit.py check --inventory /inventory.json --concurrency 4

# The profile probe is the backend's own route service, so it runs in the
# map-platform image and reaches Valhalla over a network with no way out.
network=bicino-profiles-$label
service=bicino-profiles-$label
echo "== profiles start=$(bicino_now)"
docker rm -f "$service" >/dev/null 2>&1 || true
docker network rm "$network" >/dev/null 2>&1 || true
docker network create --internal "$network" >/dev/null
docker run -d --init --name "$service" --network "$network" --platform "$BICINO_PLATFORM" --cpus 2 --memory 2g \
  --read-only --tmpfs /tmp:size=64m --label "bicino.stage=$BICINO_STAGE" \
  -v "$archive:/graph/valhalla_tiles.tar:ro" --entrypoint /bin/bash "$valhalla_image" -ec '
    valhalla_build_config --mjolnir-tile-extract /graph/valhalla_tiles.tar > /tmp/valhalla.json
    exec valhalla_service /tmp/valhalla.json 2' >/dev/null
set +e
bicino_wait_for_valhalla "$network" 300 "$service" \
  && docker run --rm --init --network "$network" --platform "$BICINO_PLATFORM" -u "$(id -u):$(id -g)" \
    --label "bicino.stage=$BICINO_STAGE" -v "$BICINO_REPO/map-platform:/mp:ro" \
    --entrypoint python3 "$BICINO_MAP_PLATFORM_IMAGE" \
    /mp/routing/probe_profiles.py --origin "http://$service:8002" > "$out/profiles.json" 2> "$out/profiles.err"
status=$?
set -e
docker rm -f "$service" >/dev/null
docker network rm "$network" >/dev/null
echo "profiles $status" >> "$out/exit-codes.txt"
echo "== profiles exit=$status end=$(bicino_now)"

python3 "$BICINO_BUILDER/qualification.py" --dir "$out" --label "$label"
