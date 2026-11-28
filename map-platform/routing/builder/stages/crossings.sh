#!/bin/bash
# Grade the roads over crossings from their ends before the graded build.
#
# A terrain model reads the ground under a bridge's deck and the channel a
# stream cuts through a road's fill, so roads beside bridges and over
# culverts read steps they do not have. crossing_stage.py finds every
# crossing inside a terrain source's area, block by block, and rewrites the
# build's OSM input once so that Valhalla grades each such stretch from its
# ends, as it grades a bridge (refresh-runbook.md, "False steps at
# crossings"). The graded build takes the rewritten roads with
# build_graph.py --crossings-from, which checks that they were made of its
# own input and tiles. It runs in the map-platform image, which has the
# pyosmium, numpy and Shapely this host lacks, with no network.
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
bicino_validate_run
bicino_is_hybrid || bicino_fail "the crossings are graded only over terrain sources"

for manifest in "$BICINO_ELEVATION/elevation-manifest.json" "$BICINO_ELEVATION_TERRAIN/terrain-manifest.json"; do
  [ -s "$manifest" ] || bicino_fail "no tile set: $manifest is missing"
done
[ -s "$BICINO_ELEVATION_TERRAIN/cells.txt" ] || bicino_fail "the terrain tiles have no cells.txt"
source_file=$(bicino_source_file)
[ -s "$source_file.sha256" ] || bicino_fail "$source_file has no verified checksum; the download stage writes it"
roads=$(bicino_roads_file)
case "$roads" in
  "$BICINO_INPUT"/*) ;;
  *) bicino_fail "$roads is not below $BICINO_INPUT" ;;
esac
if bicino_is_sample; then
  sha256=$(sha256sum "$roads" | cut -d' ' -f1)
else
  # The planet's checksum, checked by the download stage; build_graph.py checks it again.
  sha256=$(cut -d' ' -f1 "$source_file.sha256")
fi

# A killed attempt left its partial output and, maybe, its container.
bicino_remove_containers "bicino.stage=$BICINO_STAGE@$BICINO_SCRATCH"
if [ -e "$BICINO_CROSSINGS" ]; then
  echo "removing the unfinished crossings in $BICINO_CROSSINGS"
  rm -rf "$BICINO_CROSSINGS"
fi
mkdir -p "$BICINO_CROSSINGS" "$BICINO_EVIDENCE/crossings"
sha256sum "$BICINO_ROUTING/crossing_stage.py" "$BICINO_ROUTING/crossing_split.py" "$BICINO_ROUTING/crossing_steps.py"

echo "crossings start=$(bicino_now)"
set +e
docker run --rm --init --network none --platform "$BICINO_PLATFORM" -u "$(id -u):$(id -g)" \
  --label "bicino.stage=$BICINO_STAGE@$BICINO_SCRATCH" -v "$BICINO_ROUTING:/routing:ro" \
  -v "$BICINO_INPUT:/input:ro" -v "$BICINO_ELEVATION:/hybrid:ro" -v "$BICINO_ELEVATION_TERRAIN:/terrain:ro" \
  -v "$BICINO_CROSSINGS:/crossings" --entrypoint python3 "$BICINO_MAP_PLATFORM_IMAGE" \
  /routing/crossing_stage.py --source "/input/${roads#"$BICINO_INPUT"/}" --source-sha256 "$sha256" \
  --elevation /hybrid --terrain /terrain --sources /routing/elevation-sources.json --out /crossings \
  --jobs "$BICINO_CROSSING_JOBS" 2>&1 \
  | while IFS= read -r line; do printf '%s %s\n' "$(bicino_now)" "$line"; done
status=${PIPESTATUS[0]}
set -e
echo "crossings exit=$status end=$(bicino_now)"
[ "$status" -eq 0 ] || bicino_fail "crossing_stage.py failed; its error is above"
[ -s "$BICINO_CROSSINGS/crossings.json" ] || bicino_fail "crossing_stage.py wrote no record"
cp "$BICINO_CROSSINGS/crossings.json" "$BICINO_CROSSINGS/fixed-sites.json.gz" "$BICINO_EVIDENCE/crossings/"
python3 - "$BICINO_CROSSINGS/crossings.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
stage = record["stage"]
print(f"crossings: {stage['terrainCells']} terrain cells, {stage['blocks']} blocks, found {stage['sitesFound']}; "
      f"{record['fixedSites']} sites fixed, {record['waysChanged']} ways changed, "
      f"{record['piecesGradedFromEnds']} pieces graded from their ends")
PY
