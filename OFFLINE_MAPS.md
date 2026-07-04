# Offline Maps

Use the `OSM_Extract` toolchain to generate OpenStreetMap vector blocks for the
device map renderer. The recommended path is the provided Docker environment,
which includes `osmium`, `ogr2ogr`, and the required Python dependencies.

## 1. Download a PBF extract

Use BBBike Extract in PBF format: https://extract.bbbike.org/

Save the resulting file to:

```text
OSM_Extract/pbf/<your-area>.osm.pbf
```

## 2. Run the extractor in Docker

```sh
cd OSM_Extract
docker compose run --rm tools bash
```

If you have an older Docker install, use `docker-compose` instead of
`docker compose`.

Inside the container:

```sh
cd /scripts

# Get the file's bounding box and copy values into the vars below.
osmium fileinfo -g header.box /pbf/<your-area>.osm.pbf

min_lon=...
min_lat=...
max_lon=...
max_lat=...

# Generates: /maps/<your-area>_lines.geojson and /maps/<your-area>_polygons.geojson
./pbf_to_geojson.sh "$min_lon" "$min_lat" "$max_lon" "$max_lat" "/pbf/<your-area>.osm.pbf" "/maps/<your-area>"

# Generates a folder tree of vector blocks under /maps/<output-name>/
./extract_features.py "$min_lon" "$min_lat" "$max_lon" "$max_lat" "/maps/<your-area>" "/maps/<output-name>"
```

Outputs on the host machine:

```text
OSM_Extract/maps/<output-name>/
```

The output folder contains generated `.fmb` / `.fmp` vector map blocks.

Config knobs:

- Feature selection: `OSM_Extract/conf/conf_extract.yaml`
- Styling: `OSM_Extract/conf/conf_styles.yaml`

## 3. Copy maps to SD card

Copy the generated map folders to the SD card under:

```text
/VECTMAP/<output-name>/
```

The ESP32 firmware reads `.fmb` blocks from this layout for offline map
rendering. The XIAO nRF52840 target has an experimental map-lite probe/render
path that uses the same folder structure for hardware go/no-go testing.
