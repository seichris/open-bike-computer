#!/usr/bin/env python
from funcs import process_features, clip_lines, clip_polygons, style_features, render_map, lat2y, lon2x
from feature_types import get_type_id
from map_format import write_fmb
from shapely import box
import json, yaml
import os, sys

if len( sys.argv ) < 2: 
    print(" No arguments provided.")
    print(" Usage:")
    print("      {} <min_lon> <min_lat> <max_lon> <max_lat> <geojson prefix name>".format( sys.argv[0]))
    print("")
    sys.exit()

LINES_INPUT_FILE = "{}_lines.geojson".format( sys.argv[5] )
POLYGONS_INPUT_FILE = "{}_polygons.geojson".format( sys.argv[5] )
CONF_FEATURES = '../conf/conf_extract.yaml'
CONF_STYLES = '../conf/conf_styles.yaml'
MAP_FOLDER = sys.argv[6] if len(sys.argv) > 6 else '../maps/shanghai_v2'

MAPBLOCK_SIZE_BITS = 12     # 4096 x 4096 coords (~meters) per block  
MAPFOLDER_SIZE_BITS = 4     # 16 x 16 map blocks per folder
mapblock_mask  = pow( 2, MAPBLOCK_SIZE_BITS) - 1     # ...00000000111111111111
mapfolder_mask = pow( 2, MAPFOLDER_SIZE_BITS) - 1    # ...00001111

conf = yaml.safe_load( open( CONF_FEATURES, "r"))
styles = yaml.safe_load( open(CONF_STYLES, "r"))

min_lon, min_lat, max_lon, max_lat = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
area_min_x, area_min_y = lon2x( float( min_lon)), lat2y( float( min_lat))
area_max_x, area_max_y = lon2x( float( max_lon)), lat2y( float( max_lat))

print("  Step 1/5 reading lines files")
lines = json.load( open( LINES_INPUT_FILE, "r"))
print("  Step 2/5 reading polygons files")
polygons = json.load( open( POLYGONS_INPUT_FILE, "r"))

# extract relevant features
print("Extracting features")
lines = process_features( lines['features'], conf['lines']) # extracted_lines
polygons = process_features( polygons['features'], conf['polygons']) # extracted_polygons
print("Applying styles")
# apply styles
lines = style_features( lines, styles) # styled_lines
polygons = style_features( polygons, styles) # styled_polygons
# polygons = make_all_convex( polygons)

total = ((area_max_x - area_min_x)/4096) * ((area_max_y - area_min_y)/4096)
done = 0
for init_x in range(area_min_x, area_max_x, 4096):
    for init_y in range(area_min_y, area_max_y, 4096):
        # print("--------------------")
        # print("init_x, init_y", init_x, init_y)
        min_x = init_x & (~mapblock_mask)
        min_y = init_y & (~mapblock_mask)
        mapblock_bbox = box( min_x, min_y, min_x + mapblock_mask, min_y + mapblock_mask + 1) # we add 1 in max_y to compensate rounding errors when rendering

        # clip features to the block area
        clipped_lines = clip_lines( lines, mapblock_bbox)
        clipped_polygons = clip_polygons( polygons, mapblock_bbox)
        if len(clipped_lines) == 0 and len( clipped_polygons) == 0:
            done += 1
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
        if os.path.exists(f"{file_name}.fmb"):
            done += 1
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
        write_fmb(
            f"{file_name}.fmb",
            clipped_polygons,
            clipped_lines,
            min_x,
            min_y,
        )

        done += 1
        print("  Step 5/5 Building map. {:.0%}  ".format(done/total), end='\r')

