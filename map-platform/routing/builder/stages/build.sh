#!/bin/bash
# Build one Valhalla archive: build.sh ungraded | graded.
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"
bicino_validate_run

label=${1:-}
case "$label" in
  ungraded) threads=$BICINO_UNGRADED_THREADS; arguments=() ;;
  graded)
    threads=$BICINO_GRADED_THREADS
    [ -s "$BICINO_ELEVATION/elevation-manifest.json" ] || bicino_fail "no elevation manifest in $BICINO_ELEVATION"
    sha256sum "$BICINO_ELEVATION/elevation-manifest.json"
    arguments=(--elevation "$BICINO_ELEVATION")
    ;;
  *) bicino_fail "usage: build.sh ungraded|graded" ;;
esac
# A terrain model holds the ground under a deck, so its graph marks every
# bridge as one. The ungraded twin does too: the gate compares graphs that
# differ in elevation alone.
if bicino_is_hybrid; then
  arguments+=(--all-bridges)
fi

source_file=$(bicino_source_file)
[ -s "$source_file.sha256" ] || bicino_fail "$source_file has no verified checksum; the download stage writes it"
roads=$(bicino_roads_file)
if bicino_is_sample; then
  sha256=$(sha256sum "$roads" | cut -d' ' -f1)
  arguments+=(--sample --admin-source "$BICINO_INPUT/sample/admin.osm.pbf")
else
  # build_graph.py hashes the planet itself and refuses a file that differs.
  sha256=$(cut -d' ' -f1 "$source_file.sha256")
  arguments+=(--coverage planet)
fi

# build_graph.py needs a new directory. One without a manifest is what a
# killed attempt left, with the container that was still writing into it.
work=$BICINO_BUILD/planet-$label
mkdir -p "$BICINO_BUILD"
bicino_remove_containers "bicino.work=$work"
if [ -e "$work" ]; then
  [ ! -e "$work/manifest.json" ] || bicino_fail "$work already holds a finished build"
  echo "removing the unfinished build in $work"
  rm -rf "$work"
fi

sha256sum "$BICINO_ROUTING/build_graph.py"
echo "build start=$(bicino_now) threads=$threads"
# GNU time reports to a file of its own: after a failure the end of this log
# is then the build's error, which the status shows, not time's statistics.
timing=$BICINO_LOGS/$BICINO_STAGE.time
if ! /usr/bin/time -v -o "$timing" python3 "$BICINO_ROUTING/build_graph.py" \
  --source "$roads" --source-sha256 "$sha256" --source-url "$(bicino_source_url)" \
  "${arguments[@]}" --work "$work" --threads "$threads"; then
  bicino_fail "build_graph.py failed; its error is above and its resource use in $timing"
fi
echo "build end=$(bicino_now)"
cat "$timing"
[ -s "$work/manifest.json" ] || bicino_fail "build_graph.py wrote no manifest"
cat "$work/manifest.json"
