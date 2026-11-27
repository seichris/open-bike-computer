#!/bin/bash
# Scan the graded build's terrain tiles for artifacts and the roads they give a false step.
#
# terrain_artifacts.py reads the terrain, opened and hybrid tiles with no
# network, then asks /locate of the graded archive, served on an internal
# network of this stage's own, for the edges beside every steep hollow, and
# writes a short report to export/evidence/terrain-scan/. What it finds is
# the report's answer, not a failed stage: the stage fails only when the scan
# or a lookup could not be made.
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
bicino_validate_run
bicino_is_hybrid || bicino_fail "the terrain scan needs terrain sources"

archive=$BICINO_BUILD/planet-graded/valhalla_tiles.tar
[ -s "$BICINO_BUILD/planet-graded/manifest.json" ] || bicino_fail "no finished graded build"
for manifest in "$BICINO_ELEVATION_TERRAIN/terrain-manifest.json" "$BICINO_ELEVATION_OPENED/elevation-manifest.json" \
  "$BICINO_ELEVATION/elevation-manifest.json"; do
  [ -s "$manifest" ] || bicino_fail "no tile set: $manifest is missing"
done
out=$BICINO_EVIDENCE/terrain-scan
host=bicino-scan-graded
network=bicino-scan-$BICINO_RUN_ID
valhalla_image=$(bicino_valhalla_image)
mkdir -p "$out"
rm -f "$out/scan.json" "$out/pits.jsonl.gz" "$out/roads.json.gz" "$out/terrain-report.json" "$out/terrain-report.md"
sha256sum "$BICINO_ROUTING/terrain_artifacts.py"

cleanup() {
  bicino_remove_containers "bicino.stage=$BICINO_STAGE@$BICINO_SCRATCH" || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# in_scan NETWORK COMMAND...: terrain_artifacts.py in the map-platform image.
in_scan() {
  local on=$1
  shift
  docker run --rm --init --network "$on" --platform "$BICINO_PLATFORM" -u "$(id -u):$(id -g)" \
    --label "bicino.stage=$BICINO_STAGE@$BICINO_SCRATCH" -v "$BICINO_ROUTING:/routing:ro" \
    -v "$BICINO_ELEVATION_TERRAIN:/terrain:ro" -v "$BICINO_ELEVATION_OPENED:/opened:ro" \
    -v "$BICINO_ELEVATION:/hybrid:ro" -v "$out:/out" \
    --entrypoint python3 "$BICINO_MAP_PLATFORM_IMAGE" /routing/terrain_artifacts.py "$@" 2>&1 \
    | while IFS= read -r line; do printf '%s %s\n' "$(bicino_now)" "$line"; done
  return "${PIPESTATUS[0]}"
}

echo "scan start=$(bicino_now)"
in_scan none scan --terrain /terrain --opened /opened --hybrid /hybrid --out /out --jobs "$BICINO_ELEVATION_JOBS"
echo "scan end=$(bicino_now)"

# The graded graph, whose edges carry the slopes the hybrid gave them. It
# answers to $host on the stage's network, which has no way out.
docker network create --internal --label "bicino.stage=$BICINO_STAGE@$BICINO_SCRATCH" "$network" >/dev/null
docker run -d --init --name "$host-$BICINO_RUN_ID" --network "$network" --network-alias "$host" \
  --platform "$BICINO_PLATFORM" --cpus 4 --memory 8g \
  --read-only --tmpfs /tmp:size=64m --label "bicino.stage=$BICINO_STAGE@$BICINO_SCRATCH" \
  -v "$archive:/graph/valhalla_tiles.tar:ro" --entrypoint /bin/bash "$valhalla_image" -ec '
    valhalla_build_config --mjolnir-tile-extract /graph/valhalla_tiles.tar > /tmp/valhalla.json
    exec valhalla_service /tmp/valhalla.json 4' >/dev/null
bicino_wait_for_valhalla "$network" 300 "$host"

echo "roads start=$(bicino_now)"
set +e
in_scan "$network" roads --dir /out --url "http://$host:8002" --jobs 8
roads=$?
set -e
echo "roads exit=$roads end=$(bicino_now)"

sample=()
if bicino_is_sample; then
  sample=(--sample)
fi
in_scan none report --dir /out ${sample[@]+"${sample[@]}"}
cat "$out/terrain-report.md"
[ "$roads" -eq 0 ] || bicino_fail "the road check could not look up every hollow (exit $roads); see roads.json.gz"
