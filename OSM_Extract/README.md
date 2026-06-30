# OSM_Extract

https://github.com/aresta/OSM_Extract

This tools are created to extract OpenStreetMap vectorial map features to *fmp* files (text with specific format) to be used by other projects to display custom maps with a subset of features and a custom styling.

For example, you can store the generated files in an SD card and use it to render maps in your custom device.

This is intended to be used in projects with microcontrollers involving GPS location and display capabilities. But it can be used in any project that needs to render simple vectorial maps.

Features:
- The area to be extracted can be configured in **/conf/clip_area.geojson**. 

- The script **/scripts/pbf_to_geojson.sh** is used to do the extraction.

- The feature types to be extracted can be configured in **/conf/conf_extract.yaml**

- The styles to apply to each feature type (color, width...) can be configured in **conf_styles.yaml**

It produces custom text files with the vectorial data of the features: lines and polygons, with the style information.

The map files are organized in a folder tree structure. Each folder contains several map files and has a custom name that defines the offset position of the map files in the folder.

Each file contains the vectorial data of an area of approximately 4x4 Kms. 

Each folder contains up to 256 files (16x16 blocks), so it covers an approximate area of 64x64 Kms.  You can have as many folders as you need to cover your map area.

This is already used and working in the project: https://github.com/aresta/ESP32_GPS

Still work in progress.

## Setup

The recommended workflow is Docker Compose from this directory:

```bash
docker compose run --rm tools bash
```

The container mounts:
- `./pbf` as `/pbf` (read-only input PBF files)
- `./maps` as `/maps` (generated outputs)
- `./scripts` as `/scripts`
- `./conf` as `/conf` (read-only configuration)

For host-only development, this project requires `shapely`, `PyYAML`, and `Pillow`. Use a virtual environment:

```bash
cd scripts
python3 -m venv venv
source venv/bin/activate
pip install shapely PyYAML Pillow
```

## Example of the creation of the map files

1. Download the OpenStreetMap **PBF** file of your ares with all the map features.  You can find them in [Geofabrik](https://download.geofabrik.de/) or https://download.openstreetmap.fr/extracts/

For example: *spain-latest.osm.pbf*


2. Clip the PBF to your area:

```
osmium extract --strategy=smart -p /conf/clip_area.geojson /pbf/spain-latest.osm.pbf -o /maps/clipped.pbf
```
It will generate a smaller PBF file of a reduced area, defined by the clipping square in *clip_area.geojson*.


3. Generate the intermediate lines and polygons files extracting only the defined subset of feature types:
```
min_lon=123
min_lat=123
max_lon=123
max_lat=123

./pbf_to_geojson.sh $min_lon $min_lat $max_lon $max_lat /maps/clipped.pbf /maps/test
echo "PBF extract done"
```

4. And finally generate the compiled map files in a specific output folder:
```bash
./extract_features.py $min_lon $min_lat $max_lon $max_lat /maps/test /maps/output_folder
echo "Map files created"
```

The script takes 6 arguments:
1. `min_lon`
2. `min_lat`
3. `max_lon`
4. `max_lat`
5. `geojson_prefix`: Prefix of the `.geojson` files generated in Step 3.
6. `output_folder` (Optional): Where the `.fmp` and `.fmb` files will be saved. Defaults to `../maps/shanghai_v2`.

These files will contain the feature types defined in */conf/conf_extract.yaml* of your area, with the visual styles defined in */conf/conf_styles.yaml*
