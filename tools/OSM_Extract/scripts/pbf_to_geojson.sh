#!/bin/bash
set -euo pipefail

# OpenStreetMap uses the WGS84 spatial reference system
# Most tiled web maps (such as the standard OSM maps and Google Maps) use this Mercator projection.
# WGS84 (EPSG 4326) => Mercator (EPSG 3857)

# First download the big pbf file of your area and store it in /pbf Check: https://download.geofabrik.de/

# Uncomment to clip the big pbf file to a reduced area. Adjust the clip_xxx.geojson clipping area -> check: http://geojson.io
# osmium extract --strategy=smart -p /conf/clip_area.geojson /pbf/spain-latest.osm.pbf -o /maps/clipped.pbf


# Extract the lines and polygons from the clipped pbf file
if [ "$#" -lt 6 ]; then
    echo "Invalid arguments."
    echo " Usage:"
    echo "      $0 <min_lon> <min_lat> <max_lon> <max_lat> <pbf input file> <output file name> [--renderer-format 1|2|3|4] [source index manifest] [scope plan] [relation retry count] [closure plan]"
    echo ""
    exit 1
fi

min_lon="$1"
min_lat="$2"
max_lon="$3"
max_lat="$4"
source_pbf="$5"
output_prefix="$6"
shift 6

renderer_format=1
if [ "${1:-}" = "--renderer-format" ]; then
    if [ "$#" -lt 2 ]; then
        echo "Missing renderer format."
        exit 1
    fi
    renderer_format="$2"
    shift 2
fi
case "$renderer_format" in
    1|2|3|4) ;;
    *)
        echo "Invalid renderer format."
        exit 1
        ;;
esac
if [ "$#" -ne 0 ] && [ "$#" -ne 3 ] && [ "$#" -ne 4 ]; then
    echo "Invalid selected-area arguments."
    exit 1
fi

rm -f "${output_prefix}_lines.geojson"
rm -f "${output_prefix}_polygons.geojson"
rm -f "${output_prefix}_points.geojson"
rm -f "${output_prefix}_building_relations.json"
ogr_options=(--config OGR_INTERLEAVED_READING YES)
if [ "$#" -eq 3 ]; then
    # Selected mode has already bounded the PBF and rehydrated the exact source-index
    # relation closure. Expose even tagless required member ways so strict relation
    # handling can recover their geometry instead of depending on ordinary OSM tags.
    selected_osm_config="$(cd "$(dirname "$0")/../conf" && pwd)/osmconf-selected-building-closure.ini"
    ogr_options+=(--config OSM_CONFIG_FILE "$selected_osm_config")
fi
if [ "$#" -eq 4 ]; then
    ogr_options+=(--config OSM_CONFIG_FILE "$(cd "$(dirname "$0")/../conf" && pwd)/osmconf-selected-building-closure.ini")
fi
ogr2ogr "${ogr_options[@]}" -t_srs EPSG:3857 -spat "$min_lon" "$min_lat" "$max_lon" "$max_lat" "${output_prefix}_lines.geojson" "$source_pbf" lines
ogr2ogr "${ogr_options[@]}" -t_srs EPSG:3857 -spat "$min_lon" "$min_lat" "$max_lon" "$max_lat" "${output_prefix}_polygons.geojson" "$source_pbf" multipolygons
if [ "$renderer_format" -eq 4 ]; then
    ogr2ogr "${ogr_options[@]}" -t_srs EPSG:3857 -spat "$min_lon" "$min_lat" "$max_lon" "$max_lat" "${output_prefix}_points.geojson" "$source_pbf" points
fi
if [ "$#" -eq 3 ]; then
    python "$(dirname "$0")/extract_building_relations.py" "$source_pbf" "${output_prefix}_building_relations.json" \
        --source-index-manifest "$1" --scope-plan "$2" --relation-retry-count "$3"
elif [ "$#" -eq 4 ]; then
    python "$(dirname "$0")/extract_building_relations.py" "$source_pbf" "${output_prefix}_building_relations.json" \
        --source-index-manifest "$1" --scope-plan "$2" --relation-retry-count "$3" \
        --closure-plan "$4"
else
    python "$(dirname "$0")/extract_building_relations.py" "$source_pbf" "${output_prefix}_building_relations.json"
fi
