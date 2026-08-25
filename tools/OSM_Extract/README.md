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

For host-only development, this project requires `shapely`, `PyYAML`,
`Pillow`, `freetype-py`, `uharfbuzz`, and Pyosmium. Use a virtual environment:

```bash
cd scripts
python3 -m venv venv
source venv/bin/activate
pip install "shapely==2.0.7" PyYAML Pillow freetype-py uharfbuzz "osmium==4.3.1"
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

## Renderer formats and OSM 3D buildings

`extract_features.py --renderer-format` selects the durable binary output:

- format 1 writes the existing FMB v2 blocks;
- format 2 writes FMB v3 blocks plus the shared FMA1 street-label asset; and
- format 3 writes FMB v4 blocks with the same label sections plus the bounded
  building section documented in [`docs/fmb-v4.md`](../../docs/fmb-v4.md).

The format-3 stage reads `building=*` and `building:part=*` ways and
multipolygon relations directly from the clipped Geofabrik/OSM PBF. It keeps
holes, relation membership, OSM height tags, source edge identity, and a stable
source key. `building_height_rules.yaml` defines all accepted ranges and the
deterministic fallback ladder: explicit height, OSM levels, eligible parent
inheritance, local OSM median, then checked-in building-class default. No
external height or building source is queried.

Every renderable format-3 building therefore has a resolved height even when it
has no usable height-related OSM tags. A part first inherits an eligible
explicit or levels-derived parent height. Otherwise, the pipeline uses the
median of at least three explicit or levels-derived OSM samples from the same
coarse building class in the configured fixed cell and halo. If no eligible
median exists, it uses these checked-in class defaults:

| Normalized OSM building class | Default height |
| --- | ---: |
| `apartments` | 15 m |
| `commercial` | 12 m |
| `house` | 6 m |
| `industrial` | 9 m |
| `office` | 15 m |
| `residential` | 9 m |
| `retail` | 6 m |
| `school` | 9 m |
| `shed` | 3 m |
| `warehouse` | 9 m |
| unknown / generic | 9 m |

The source of truth is
[`conf/building_height_rules.yaml`](conf/building_height_rules.yaml), which also
sets the 3 m floor-height assumption, 2.5 m roof-level assumption, class safety
ranges, 8,192 m calibration cell, one-cell halo, and three-sample minimum.
Malformed or contradictory height tags are counted in build diagnostics and
fall through to the next valid resolution step instead of rejecting the map.
FMB v4 stores the selected provenance separately from the height value.

Legacy format-3 builds use the historical 8,192-metre calibration-cell halo
around the aligned extent. Plan-aware selected-area builds instead receive the
exact ordered output-block set, a bounded geometry buffer, source-snapshot
relation closure, and a sealed full-source calibration generation. Calibration
therefore stays stable across overlapping requests without expanding each job's
feature preparation to the calibration halo. No external enrichment is used.
Selected conversion uses `conf/osmconf-selected-building-closure.ini` after the
bounded PBF has been merged with that closure. Its `report_all_ways=yes` setting
keeps completely tagless `type=building` outline/part member geometry visible
to strict relation processing; ordinary legacy conversions retain GDAL's
default filtering, and unrelated tagless ways are rejected by building
collection.

A `type=building` relation may declare several explicit `outline` members for
one building complex. Those members are not competing relations: the relation
index records them as the only allowed parent candidates for each part, and
the spatial association stage selects the smallest declared outline that
contains the part. Explicit relation candidates permit up to 25 cm of boundary
drift to accommodate nearly coincident OSM rings; ordinary inferred
containment keeps its 5 cm tolerance. If GDAL suppresses a sole closed outer
way because it also emits an enclosing building multipolygon, the relation
index restores that exact relation geometry under the way's outline identity.
A missing or non-unique geometry provider, a part outside every declared
outline tolerance, or a part shared across different building relations still
fails closed.

Buildings are clipped only when FMB blocks are emitted; new clip edges receive
a cleared wall bit so adjacent blocks do not render artificial seam facades.
Plan-aware builds cache the canonical FMB building section for each global
4,096-metre block. The cache identity binds the source snapshot, height rules,
sealed calibration generation, building/profile and FMB versions, the pinned
geometry engine, spatial normalization and block-encoding algorithms,
source-index/closure algorithms,
and block-grid semantics. It deliberately excludes request bounds, languages,
roads, and labels. Cached sections can therefore be composed with a new
request's label and non-building sections without aliasing request-specific
content. Misses use deterministic STRtree part association and bounded parallel
block clipping/encoding; publication uses per-block cross-process locks,
content hashes, atomic manifests, and corruption-triggered recomputation.

Plan-aware runs emit exactly one canonical `BUILDING_SCOPE` marker, structured
`BUILDING_PREPROCESS_PROGRESS` markers while source/index/calibration work is in
flight, one bounded `BUILDING_COMPLEXITY` marker immediately after the already
required source-building materialization and before containment/height
normalization, and final `BUILDING_STATS` with encoded-record provenance and
seam diagnostics. Complexity includes outline/part counts, unresolved
containment candidate product, polygon/ring/hole and vertex counts, and known
preparation rejections. Final statistics also report actual spatial candidates,
prepared outlines, cache hits/misses/race hits, lock wait, and lookup/generation
timings; it does not add a second geometry parse. The backend
strictly validates these counters, uses them only for advisory preparation-time
refinement/monitoring, validates the scope marker against the frozen plan, and
keeps calibration units separate from block progress. No complexity field is
part of the FMB, manifest, or reuse identity.
