# Regional elevation ingestion and normalization

Development-only continuation of the
[2026-09-13 research implementation](research/topography-report-implementation-2026-09-13.md).
Native data acquisition, transformation, contour production and artifact encoding
are implemented as explicit operator steps. No source approval, public job route,
app installation, firmware build or deployment is implied.

## Workflow

Use the existing Python environment with the `topography` extra. It now pins
`pyproj==3.6.1` (compatible with the backend's Python 3.10 baseline) as well as
Rasterio/NumPy/contourpy. Installing a prebuilt Python dependency is separate from
building the app or firmware. Both Rasterio's and pyproj's PROJ runtime versions
are recorded because they need not bundle the same PROJ release.

```sh
# First capture provider metadata with the existing discover command.
.venv-topography/bin/map-topography --cache "$terrain_cache" regional-stage \
  --discovery /absolute/path/discovery.json \
  --item-id EXACT_ITEM_ID_FROM_DISCOVERY \
  --output /absolute/path/new-native-receipt.json

.venv-topography/bin/map-topography --cache "$terrain_cache" regional-inspect \
  --receipt /absolute/path/new-native-receipt.json \
  --output /absolute/path/new-native-inspection.json

# Complete and review the inspection's draftContract and stage its exact grid
# files. Null fields deliberately make the unreviewed draft unusable.
.venv-topography/bin/map-topography --cache "$terrain_cache" regional-sample \
  --receipt /absolute/path/new-native-receipt.json \
  --source-contract /absolute/path/reviewed-transform-contract.json \
  --grid-directory /absolute/path/pinned-transformation-grids \
  --bounds WEST SOUTH EAST NORTH \
  --output /absolute/path/new-regional-contours.json

.venv-topography/bin/map-topography --cache "$terrain_cache" encode \
  --sample /absolute/path/new-regional-contours.json \
  --source-contract /absolute/path/reviewed-transform-contract.json \
  --selection /absolute/path/selection.geojson \
  --vector-pack /absolute/path/vector-pack --map-id YOUR_MAP_ID \
  --attribution /absolute/path/complete-source-notices.txt \
  --output /absolute/path/new-development-pair
```

Every explicit output refuses overwrite. `regional-stage` replays captured
catalog metadata offline through the original provider adapter before trusting
the snapshot's normalized asset claims. Provider checksums are enforced when
present; an absent provider checksum is not replaced by an invented one. After
acquisition, a local SHA-256 identifies the actual retained bytes. Changed cached
bytes fail on reuse instead of being silently replaced. Interrupted or invalid
transfers do not publish a receipt.

The current whole-object staging bound is **128 MiB per TIFF**, with the existing
socket/deadline, disk-reserve and locking rules. Some national mosaic assets are
much larger and will be rejected. The tool does not evade that bound through
unverified HTTP ranges or silently download the full national collection. The
next ingestion extension needs version/checksum-bound range caching or qualified
native subtiles; large-asset support is not claimed here.

## Exact transformation contract

The inspection output contains a draft with these required fields:

| Field | Contract |
| --- | --- |
| `schemaVersion` | Integer `1`. |
| `sourceId`, `assetSha256` | Exact source and retained native TIFF identity. |
| `sourceReviewSha256` | Identity of the operator's source/frame/datum review; not an automatic approval or signature. |
| `sourceVerticalDatum` | Explicit native realization, not inferred from country or raster horizontal CRS. |
| `targetVerticalDatum` | `EPSG:3855`, EGM2008 heights in metres. |
| `native` | Exact horizontal EPSG code, band dtype, declared no-data (number, `"nan"`, or null), and observed band-unit label. Scale/offset must be 1/0. |
| `areaOfUse` | Non-wrapped WGS84 W/S/E/N bounds reviewed for both operations; the processing halo must fit too. Not a jurisdiction boundary. |
| `horizontalPipeline` | Explicit PROJ text and its UTF-8 SHA-256: WGS84 longitude/latitude degrees to native raster X/Y. |
| `verticalPipeline` | Explicit PROJ text and its UTF-8 SHA-256: WGS84 longitude/latitude degrees plus native metre height to the same longitude/latitude plus EGM2008 metre height. |
| `grids` | Exact filename, byte length and SHA-256 for every `{filename}` placeholder used in either pipeline. |
| `productionApproved` | Must remain `false`; this operator contract cannot enable production. |

Pipeline syntax and operation/parameter names are allowlisted. Named database
lookups, implicit datum/grid references, optional grids, `null` fallback grids,
remote paths and undeclared grids are rejected. Non-EGM2008 input requires an
explicit vertical-grid operation. PROJ networking must already be disabled;
the engine does not change another caller's global network configuration.

Grid files are copied into a private, size/hash-verified snapshot before PROJ
opens them. An open transformation therefore continues to use its original
bytes if the source grid file changes; a later invocation rejects the change.
Copies are removed when the transformation context closes. Pipeline identity
records the portable placeholders, never the temporary directory name.

The current operation contract is **static**, not time-dependent. Operations
requiring an observation epoch or coupled height-dependent horizontal correction
need a separate qualified contract; epoch/rate parameters are rejected rather
than given implicit defaults. The vertical operation must preserve horizontal
coordinates to 1e-9 degrees. Caller-supplied operation text and a review digest
do not, by themselves, prove geodetic correctness or legal eligibility.

## Raster and contour behavior

- Native TIFFs are opened locally, never as a remote GDAL dataset or VRT.
- Dimensions, band count/type, CRS, units, no-data, scale/offset and north-up
  affine geometry must match the supplied contract.
- Reads use bounded native windows, recursively split when a high-resolution
  input would exceed four million window pixels. Cancellation is checked between
  bounded sampling chunks.
- Internal masks, non-finite samples and declared no-data are honored before
  interpolation. Every contributing bilinear neighbor must be valid; negative
  terrain remains valid and missing terrain does not become sea level.
- Both transformations fail outside their reviewed area or on unavailable grids.
  Invalid output heights and unexpected horizontal movement fail the operation.
- The normalized raster uses the fixed processing grid/halo and the shared
  contour extractor. Regional output currently keeps the already-supported
  30 m working grid and 20/100 m contour intervals. It does not advertise a new
  5 m/10 m firmware profile or imply that 30 m resampling is survey accuracy.
- Encoding requires the exact source contract again. Device blocks and iPhone
  companion tiles consume the same contour intermediate, retaining the existing
  artifact separation and attribution binding.

This stage processes one selected native asset. It neither chooses between
overlapping survey editions nor automatically blends regional DTM with global
DSM. Source-boundary residual QA, water/quality-mask ingestion, and multi-asset
selection remain explicit follow-ups, not hidden feathering or offsets.

## Evidence, 2026-09-13

Python tests cover discovery replay, immutable/native-checksum staging, strict
contract rejection, exact-grid snapshots, actual synthetic vertical-grid
interpolation, projected native sampling, window-budget invariance, cancellation,
and regional contour → device/companion CLI encoding. These are not firmware or
app builds and do not qualify physical-device rendering.

The broader Python suite completed successfully: 817 backend tests run with two
existing macOS-inapplicable skips, plus all 55 deployment tests. Three native
Swift/C++ cross-reader compilation tests were withheld under the build pause.
The final focused regional suite contains 14 tests. The earlier real Alps sample
remained byte-identical after extracting the shared contour implementation.

A live `swissalti3d_2025_2597-1194` 2 m TIFF was acquired through the new staging
path and matched its published SHA-256:
`56ce4b84bef4de35b5a5eb8566fa1064645787dac5bb2e330bbbd232ca1c7bcd`.
Observed header: 1,074,531 bytes; 500×500 Float32; EPSG:2056; no-data -9999;
band units `metre`; scale/offset 1/0; pixel registration `Area`.

This real native tile has **not** been represented as an approved EGM2008 map.
A read-only local PROJ check found no available non-ballpark LN02→EGM2008
operation. Its candidate paths require missing grids, including
`ch_swisstopo_chgeo2004_ETRS89_LN02.tif` and `us_nga_egm08_25.tif`.
Grid licensing, source/frame assumptions and operation qualification must be
completed before generating a reviewed Swiss map. The successful conversion test
uses a clearly synthetic constant-offset grid, not a fabricated Swiss correction.

Implementation references:
[pyproj 3.6.1 Transformer](https://pyproj4.github.io/pyproj/3.6.1/api/transformer.html),
[PROJ vertical grid shift](https://proj.org/en/stable/operations/transformations/vgridshift.html).
