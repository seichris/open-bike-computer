#!/bin/bash
set -euo pipefail

# OpenStreetMap uses the WGS84 spatial reference system
# Most tiled web maps (such as the standard OSM maps and Google Maps) use this Mercator projection.
# WGS84 (EPSG 4326) => Mercator (EPSG 3857)

# First download the big pbf file of your area and store it in /pbf Check: https://download.geofabrik.de/

# Uncomment to clip the big pbf file to a reduced area. Adjust the clip_xxx.geojson clipping area -> check: http://geojson.io
# osmium extract --strategy=smart -p /conf/clip_area.geojson /pbf/spain-latest.osm.pbf -o /maps/clipped.pbf


# Extract the lines and polygons from the clipped pbf file
if [ "$#" -ne 6 ] && [ "$#" -ne 9 ]; then
    echo "Invalid arguments."
    echo " Usage:"
    echo "      $0 <min_lon> <min_lat> <max_lon> <max_lat> <pbf input file> <output file name> [source index manifest] [scope plan] [relation retry count]"
    echo ""
    exit 1
fi

rm -f "${6}_lines.geojson"
rm -f "${6}_polygons.geojson"
rm -f "${6}_building_relations.json"
ogr_options=(--config OGR_INTERLEAVED_READING YES)
if [ "$#" -eq 9 ]; then
    # Selected mode has already bounded the PBF and rehydrated the exact source-index
    # relation closure. Expose even tagless required member ways so strict relation
    # handling can recover their geometry instead of depending on ordinary OSM tags.
    selected_osm_config="$(cd "$(dirname "$0")/../conf" && pwd)/osmconf-selected-building-closure.ini"
    ogr_options+=(--config OSM_CONFIG_FILE "$selected_osm_config")
fi
ogr2ogr "${ogr_options[@]}" -t_srs EPSG:3857 -spat "$1" "$2" "$3" "$4" "${6}_lines.geojson" "$5" lines
ogr2ogr "${ogr_options[@]}" -t_srs EPSG:3857 -spat "$1" "$2" "$3" "$4" "${6}_polygons.geojson" "$5" multipolygons
if [ "$#" -eq 9 ]; then
    python "$(dirname "$0")/extract_building_relations.py" "$5" "${6}_building_relations.json" \
        --source-index-manifest "$7" --scope-plan "$8" --relation-retry-count "$9"
else
    python "$(dirname "$0")/extract_building_relations.py" "$5" "${6}_building_relations.json"
fi
