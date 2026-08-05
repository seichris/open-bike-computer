#!/usr/bin/env python
from funcs import process_features, clip_lines, clip_polygons, style_features, render_map, lat2y, lon2x
from feature_types import get_type_id
from map_format import write_fmb
from font_asset import FontPackBuilder
from label_pipeline import join_named_roads, normalize_preferred_languages, prepare_road_labels
from block_progress import BlockProgressReporter
from building_pipeline import (
    clip_buildings,
    collect_building_features,
    load_relation_index,
    load_rules,
    prepare_buildings,
    projected_selection_geometry,
)
from itertools import product
from shapely import box
from shapely.geometry import shape
import argparse, json, yaml
import os, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("min_lon")
parser.add_argument("min_lat")
parser.add_argument("max_lon")
parser.add_argument("max_lat")
parser.add_argument("geojson_prefix")
parser.add_argument("map_folder", nargs="?", default="../maps/shanghai_v2")
parser.add_argument("--renderer-format", type=int, choices=(1, 2, 3), default=1)
parser.add_argument("--preferred-language", action="append", default=[])
parser.add_argument("--international-fallback", default="en")
parser.add_argument("--selection-geometry")
parser.add_argument("--selection-buffer-m", type=float, default=0.0)
args = parser.parse_args()

LINES_INPUT_FILE = "{}_lines.geojson".format(args.geojson_prefix)
POLYGONS_INPUT_FILE = "{}_polygons.geojson".format(args.geojson_prefix)
CONF_FEATURES = '../conf/conf_extract.yaml'
CONF_STYLES = '../conf/conf_styles.yaml'
MAP_FOLDER = args.map_folder

MAPBLOCK_SIZE_BITS = 12     # 4096 x 4096 coords (~meters) per block  
MAPFOLDER_SIZE_BITS = 4     # 16 x 16 map blocks per folder
mapblock_mask  = pow( 2, MAPBLOCK_SIZE_BITS) - 1     # ...00000000111111111111
mapfolder_mask = pow( 2, MAPFOLDER_SIZE_BITS) - 1    # ...00001111

conf = yaml.safe_load( open( CONF_FEATURES, "r"))
styles = yaml.safe_load( open(CONF_STYLES, "r"))

min_lon, min_lat, max_lon, max_lat = args.min_lon, args.min_lat, args.max_lon, args.max_lat
area_min_x, area_min_y = lon2x( float( min_lon)), lat2y( float( min_lat))
area_max_x, area_max_y = lon2x( float( max_lon)), lat2y( float( max_lat))
if args.renderer_format == 3:
    area_min_x &= ~mapblock_mask
    area_min_y &= ~mapblock_mask
    area_max_x = (area_max_x + mapblock_mask) & ~mapblock_mask
    area_max_y = (area_max_y + mapblock_mask) & ~mapblock_mask

print("  Step 1/5 reading lines files")
lines = json.load( open( LINES_INPUT_FILE, "r"))
print("  Step 2/5 reading polygons files")
polygons = json.load( open( POLYGONS_INPUT_FILE, "r"))

selection_geometry = None
if args.selection_geometry:
    with open(args.selection_geometry, "r", encoding="utf-8") as selection_file:
        selection_geometry = projected_selection_geometry(
            json.load(selection_file), buffer_meters=args.selection_buffer_m
        )


def selected_features(features):
    if selection_geometry is None:
        return features
    selected = []
    for feature in features:
        try:
            geometry = shape(feature.get("geometry"))
        except (TypeError, ValueError):
            continue
        if not geometry.is_empty and geometry.is_valid and geometry.intersects(selection_geometry):
            selected.append(feature)
    return selected

buildings = []
building_report = {}
building_rules_sha256 = None
if args.renderer_format == 3:
    rules_path = os.path.join(os.path.dirname(__file__), "..", "conf", "building_height_rules.yaml")
    building_rules, building_rules_sha256 = load_rules(rules_path)
    relation_index = load_relation_index(f"{args.geojson_prefix}_building_relations.json")
    buildings, building_report, _ = prepare_buildings(
        collect_building_features(polygons["features"], lines["features"]),
        building_rules,
        relation_index,
        selection_geometry,
    )

# extract relevant features
print("Extracting features")
label_diagnostics = {}
normalization_started = time.perf_counter()
lines = process_features(
    selected_features(lines['features']),
    conf['lines'],
    label_diagnostics=label_diagnostics,
) # extracted_lines
polygons = process_features(
    selected_features(polygons['features']), conf['polygons']
) # extracted_polygons
normalization_seconds = time.perf_counter() - normalization_started
print("Applying styles")
# apply styles
lines = style_features( lines, styles) # styled_lines
polygons = style_features( polygons, styles) # styled_polygons
if args.renderer_format == 3:
    polygons = [
        feature
        for feature in polygons
        if not feature["type"].startswith("building.")
    ]
font_builder = None
label_totals = {
    "blocks": 0,
    "blockBytes": 0,
    "maximumBlockBytes": 0,
    "strings": 0,
    "maximumBlockStrings": 0,
    "stringBytes": 0,
    "maximumBlockStringBytes": 0,
    "runs": 0,
    "maximumBlockRuns": 0,
    "labels": 0,
    "maximumBlockLabels": 0,
    "candidates": 0,
    "maximumBlockCandidates": 0,
}
label_phase_timings = {"labelNormalization": normalization_seconds}
if args.renderer_format >= 2:
    preferred_languages = normalize_preferred_languages(args.preferred_language)
    font_builder = FontPackBuilder(preferred_languages=preferred_languages)
    joining_started = time.perf_counter()
    lines = join_named_roads(lines, diagnostics=label_diagnostics)
    label_phase_timings["labelRoadJoining"] = time.perf_counter() - joining_started
    candidate_started = time.perf_counter()
    lines = prepare_road_labels(
        lines,
        preferred_languages=preferred_languages,
        international_fallback=args.international_fallback,
        diagnostics=label_diagnostics,
        measure_text=font_builder.measure_widths,
    )
    label_phase_timings["labelCandidateGeneration"] = time.perf_counter() - candidate_started
# polygons = make_all_convex( polygons)

x_positions = range(area_min_x, area_max_x, 4096)
y_positions = range(area_min_y, area_max_y, 4096)
total = len(x_positions) * len(y_positions)
progress = BlockProgressReporter(total)
fmb_writing_seconds = 0.0
building_totals = {
    "blocks": 0,
    "blockBytes": 0,
    "recordCount": 0,
    "pointCount": 0,
    "emittedWallCount": 0,
    "suppressedWallCount": 0,
    "droppedHoleCount": 0,
    "maximumBlockRecords": 0,
    "maximumBlockPoints": 0,
    "explicitHeightCount": 0,
    "levelsHeightCount": 0,
    "inheritedHeightCount": 0,
    "localMedianHeightCount": 0,
    "classDefaultHeightCount": 0,
}

for init_x, init_y in progress.track(product(x_positions, y_positions)):
        # print("--------------------")
        # print("init_x, init_y", init_x, init_y)
        min_x = init_x & (~mapblock_mask)
        min_y = init_y & (~mapblock_mask)
        mapblock_bbox = box( min_x, min_y, min_x + mapblock_mask, min_y + mapblock_mask + 1) # we add 1 in max_y to compensate rounding errors when rendering
        building_block_bbox = box(min_x, min_y, min_x + 4096, min_y + 4096)

        # clip features to the block area
        clipped_lines = clip_lines(
            lines,
            mapblock_bbox,
            label_diagnostics=label_diagnostics if font_builder is not None else None,
        )
        clipped_polygons = clip_polygons( polygons, mapblock_bbox)
        clipped_buildings = []
        building_block_stats = {}
        if args.renderer_format == 3:
            clipped_buildings, building_block_stats = clip_buildings(
                buildings, building_block_bbox, min_x, min_y
            )
        if (
            len(clipped_lines) == 0
            and len(clipped_polygons) == 0
            and len(clipped_buildings) == 0
        ):
            continue

        # export map files
        features, points = 0,0
        block_x = (min_x >> MAPBLOCK_SIZE_BITS) & mapfolder_mask
        block_y = (min_y >> MAPBLOCK_SIZE_BITS) & mapfolder_mask
        folder_name_x = min_x >> (MAPFOLDER_SIZE_BITS + MAPBLOCK_SIZE_BITS)
        folder_name_y = min_y >> (MAPFOLDER_SIZE_BITS + MAPBLOCK_SIZE_BITS)
        
        # folder_name numbers: sign forced (+,-) and 4 chars length, left padded with zeros. e.g: '-009+081' 
        folder_name = f"{MAP_FOLDER}/{folder_name_x:+04d}{folder_name_y:+04d}"
        file_name = f"{folder_name}/{block_x}_{block_y}"
        
        # SKIP if file already exists (RESUME feature)
        if args.renderer_format == 1 and os.path.exists(f"{file_name}.fmb"):
            print(f"  Step 5/5 Skipping existing block {block_x}_{block_y}      ", end='\r')
            continue

        os.makedirs( folder_name, exist_ok=True)
        # print(f"File: {file_name}.fmp")

        # export a png image of the block, for testing # TODO: make optional
        os.makedirs(f"{MAP_FOLDER}/test_imgs", exist_ok=True)
        render_map( features = clipped_polygons + clipped_lines, 
                file_name=f"{MAP_FOLDER}/test_imgs/block_{folder_name_x}_{folder_name_y}-{block_x}_{block_y}.png", 
                min_x=min_x, min_y=min_y)

        # TODO: order features by z_order, first the ones to be drawn below the others
        
        # ASCII VERSION (.fmp)
        if args.renderer_format == 1:
          with open( f"{file_name}.fmp", "w", encoding='ascii') as file:
            file.write( f"Polygons:{len(clipped_polygons)}\n")
            for feat in clipped_polygons:
                file.write( f"{feat['color']}\n")
                file.write( f"{feat['maxzoom']}\n")
                file.write( f"{get_type_id(feat['type'])}\n") # Type ID
                # bbox of the feature
                file.write( f"bbox:{int(round( feat['bbox'][0] - min_x))},{int(round( feat['bbox'][1] - min_y))},{int(round( feat['bbox'][2] - min_x))},{int(round( feat['bbox'][3] - min_y))}\n")
                file.write("coords:")
                for coord in feat['geom'].exterior.coords:
                    file.write( f"{int(round(coord[0] - min_x))},{int(round(coord[1] - min_y))};")
                file.write('\n')
            
            file.write( f"Polylines:{len(clipped_lines)}\n")
            for feat in clipped_lines:
                file.write( f"{feat['color']}\n")
                file.write( f"{feat['width']}\n")
                file.write( f"{feat['maxzoom']}\n")
                file.write( f"{get_type_id(feat['type'])}\n") # Type ID
                # bbox of the feature
                file.write( f"bbox:{int(round( feat['bbox'][0] - min_x))},{int(round( feat['bbox'][1] - min_y))},{int(round( feat['bbox'][2] - min_x))},{int(round( feat['bbox'][3] - min_y))}\n")
                file.write("coords:")
                for coord in feat['geom'].coords:
                    file.write( f"{int(round(coord[0] - min_x))},{int(round(coord[1] - min_y))};")
                file.write('\n')

        # BINARY VERSION (.fmb)
        block_write_started = time.perf_counter()
        block_metadata = write_fmb(
            f"{file_name}.fmb",
            clipped_polygons,
            clipped_lines,
            min_x,
            min_y,
            font_builder=font_builder,
            building_records=clipped_buildings if args.renderer_format == 3 else None,
        )
        fmb_writing_seconds += time.perf_counter() - block_write_started
        if font_builder is not None:
            label_totals["blocks"] += 1
            label_totals["blockBytes"] += block_metadata["bytes"]
            label_totals["maximumBlockBytes"] = max(
                label_totals["maximumBlockBytes"], block_metadata["bytes"]
            )
            for key in ("strings", "stringBytes", "runs", "labels", "candidates"):
                label_totals[key] += block_metadata[key]
                maximum_key = f"maximumBlock{key[0].upper()}{key[1:]}"
                label_totals[maximum_key] = max(
                    label_totals[maximum_key], block_metadata[key]
                )
        if args.renderer_format == 3:
            building_totals["blocks"] += 1
            building_totals["blockBytes"] += block_metadata["buildingBytes"]
            for key in (
                "recordCount", "pointCount", "emittedWallCount", "suppressedWallCount",
                "droppedHoleCount",
                "explicitHeightCount", "levelsHeightCount", "inheritedHeightCount",
                "localMedianHeightCount", "classDefaultHeightCount",
            ):
                building_totals[key] += building_block_stats[key]
            building_totals["maximumBlockRecords"] = max(
                building_totals["maximumBlockRecords"],
                building_block_stats["recordCount"],
            )
            building_totals["maximumBlockPoints"] = max(
                building_totals["maximumBlockPoints"],
                building_block_stats["pointCount"],
            )

if font_builder is not None:
    label_phase_timings["labelShaping"] = font_builder.shaping_seconds
    label_phase_timings["labelFmbWriting"] = max(
        0.0, fmb_writing_seconds - font_builder.shaping_seconds
    )
    font_write_started = time.perf_counter()
    font_metadata = font_builder.write(
        os.path.join(MAP_FOLDER, "assets", "street-labels.fma")
    )
    label_phase_timings["labelFontWriting"] = time.perf_counter() - font_write_started
    label_totals.update({f"font{key[0].upper()}{key[1:]}": value for key, value in font_metadata.items()})
    label_totals["diagnostics"] = label_diagnostics
    label_totals["phaseTimings"] = {
        key: round(value, 6) for key, value in label_phase_timings.items()
    }
    print("LABEL_STATS:" + json.dumps(label_totals, sort_keys=True, separators=(",", ":")))

if args.renderer_format == 3:
    for key, value in building_report.items():
        if key not in building_totals:
            building_totals[key] = value
    building_totals["rulesSha256"] = building_rules_sha256
    print("BUILDING_STATS:" + json.dumps(building_totals, sort_keys=True, separators=(",", ":")))
