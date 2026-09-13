# Free global topography: acquisition, artifacts and readers

Implementation status, 2026-09-13. Tracks [issue #190](https://github.com/seichris/open-bike-computer/issues/190)
and the [end-to-end plan](plans/issue-190-topographic-map-support-implementation-plan.md).

The maintainer-supplied 2026-09-13 research is now incorporated in source
hardening, regional metadata discovery and an executable qualification inventory.
See [report-to-implementation evidence](research/topography-report-implementation-2026-09-13.md)
for exact changes, limitations and outstanding providers. Firmware/app builds
and build-triggering pushes are paused pending maintainer confirmation.

The follow-on [regional ingestion and transformation flow](topography-regional-ingestion.md)
now stages and inspects native TIFFs, applies exact offline operation/grid
contracts, produces normalized contour samples, and encodes development device/
companion pairs. No provider has thereby gained production approval.

## What works now

- A strict, free-access source registry pins the public Copernicus 2021 tile catalogs.
- Geographic selection prefers 30 m DSM data, then 90 m where only that catalog
  contains the cell. No account, API key, rendered-tile service, or purchase is used.
- An operator CLI plans coverage, stages bounded TIFF downloads, and generates
  deterministic contour evidence from actual elevation rasters.
- Cache reuse rehashes the exact input bytes; evidence records source receipts,
  policy identity, CRS/datum, quality, missing pixels, and processing versions.
- Generation-policy v2 can describe a **disabled** contour profile. Both channels
  keep renderer format 4 disabled; even canary claims cannot enable it. The
  default policy remains v1, with the existing formats 1–3 unchanged.
- `/healthz.topography` reports `access: free` and `generationEnabled: false`.

- A bounded compiler clips one map-wide contour intermediate to polygon holes
  or a metric route corridor, projects to Web Mercator, quantizes once, and
  splits into FMB5 blocks with half-open boundary ownership. It preserves FMB4
  labels/buildings and creates terrain-only blocks with the matching font.
- The same compiled lines generate transparent XYZ PNGs at z9–16, scales 1/2,
  inside a strict read-only `.btopo` SQLite container. Device files exclude the
  companion. Output pairs bind source, selection, intermediate and attribution
  digests; a development completion receipt is published last.
- Python, C++ and Swift contour readers share a semantic-corruption corpus.
  Python and Swift companion readers validate identities, schema, tile counts,
  hashes and PNG dimensions. The Swift actor serializes SQLite reads and bounds
  its encoded-PNG cache to 4 MiB/128 entries (MapKit owns its rendering cache).
- Firmware decodes contours into flat PSRAM arrays and draws a bounded,
  index-first candidate set through the existing accepted-camera projection,
  below roads and navigation. Semantic cancellation is checked during decoding
  and drawing. The existing production installer still rejects renderer 4.
- A local MapKit tile overlay and independently owned map-view layer are
  implemented. Replacement/removal does not change routes or camera state.

This is **not yet an end-to-end topographic release**. User-job scheduling,
signed manifest/installer capability, catalog/publication/retention, durable app
download association, map selection controls, regional alignment policy, source
approval and hardware qualification remain unfinished. The new local overlay
has no user-visible saved-companion selector yet. No production generation,
capability advertisement, deployment, or physical flash has been enabled.

## Sources and actual global reach

The [AWS public dataset registry](https://registry.opendata.aws/copernicus-dem/)
describes unauthenticated public COG access. Its 2021 GLO-30 mirror has geographic
exceptions; GLO-90 supplies additional cells. This is **not** the newer/full
registered [Copernicus Data Space product](https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM).
Adding that release requires its own index, access review, and provenance.

Live catalog verification on 2026-09-12:

| Source ID | Catalog cells | Additional cells after priority selection | Nominal grid |
| --- | ---: | ---: | ---: |
| `copernicus-glo30-public-2021` | 26,450 | 26,450 | 30 m |
| `copernicus-glo90-2021` | 26,475 | 25 | 90 m |

These are one-degree geocell counts, **not percentages of countries or land**.
The 25 fallback cells lie between longitude 43–50°E and latitude 38–41°N.
An absent cell remains an explicit gap: the program cannot infer whether it is
ocean, an excluded land tile, or otherwise unavailable. Raster no-data is a
separate measurement; catalog presence does not guarantee valid pixels.

Catalog-only checks passed for sample bounds in the Alps, Netherlands, London,
Colorado, Singapore, Shanghai, Japan, Kenya, Peru, Australia, New Zealand,
Svalbard, Greenland, and Antarctica. An open-Pacific sample correctly reported
missing coverage. These checks are not MapKit alignment or physical-device proof.

Exact source contracts are in
[`topography-source-policy-v1.json`](../map-platform/config/topography-source-policy-v1.json).
The [provider's COG documentation](https://copernicus-dem-30m.s3.amazonaws.com/readme.html)
describes the geocell layout, latitude-dependent widths, and elevation reference.
The acquisition policy declares WGS84 horizontal coordinates and EGM2008 height
in metres. These are **surface** models, potentially including trees/buildings,
not a surveyed bare-earth DTM. A 20 m contour interval is not 20 m accuracy.

Swiss, Canadian and LINZ native-asset metadata discovery is implemented. A bounded
operator ingestion/normalization engine now exists, but provider-specific
transformations and production activation remain unqualified. US 3DEP and the newer
registered Copernicus baseline remain next priorities, followed by the other
sources in the research. Dataset names do not establish redistribution approval.

## Operator workflow

From the repository root, using a healthy Python 3.10–3.12 installation:

```sh
python3 -m venv .venv-topography
.venv-topography/bin/python -m pip install -e './map-platform/backend[api,test,object-storage,topography]'
terrain_cache="$(mktemp -d /tmp/bicino-topography.XXXXXX)"
.venv-topography/bin/map-topography --cache "$terrain_cache" coverage
.venv-topography/bin/map-topography --cache "$terrain_cache" plan --bounds 6.82 45.88 6.87 45.93
.venv-topography/bin/map-topography --cache "$terrain_cache" sample --bounds 6.82 45.88 6.87 45.93 --output "$terrain_cache/alps-a.json"
.venv-topography/bin/map-topography --cache "$terrain_cache" sample --bounds 6.82 45.88 6.87 45.93 --output "$terrain_cache/alps-b.json"
cmp "$terrain_cache/alps-a.json" "$terrain_cache/alps-b.json"
```

`stage` accepts the same bounds and stages receipts without contour processing.
`plan` exits 2 for missing cells. `sample` refuses any catalog gap, an oversized
request, or an existing output path. It accepts `--max-tiles` (default 8, maximum
256), but the independent four-million-pixel limit normally binds first. A
one-degree 30 m sample exceeds that pixel bound; use a small inspection area.

`sample` additionally checks the four-pixel processing halo and uses a fixed
region-wide quality profile. Thus `plan` (catalog coverage for the requested
rectangle) does not establish sampling eligibility or predict its full halo.
Selections crossing UTM zones, the equator or polar region boundaries currently
require partitioning. Resolution may be coarser than the requested rectangle's
best native input when another cell in the fixed processing region needs GLO-90.

### Review sources and discover regional native assets

These commands do not enable production or download regional rasters:

```sh
.venv-topography/bin/map-topography --cache "$terrain_cache" sources
.venv-topography/bin/map-topography --cache "$terrain_cache" discover \
  --source swissalti3d-2m --bounds 7.400 46.900 7.401 46.901 \
  --output /absolute/path/new-swiss-discovery.json
```

Other discovery source IDs are `canada-hrdem-lidar` and
`linz-national-dem-1m`. Snapshots preserve metadata/checksums and report pending
qualification gates; unknown datums remain unknown. Discovery follows all
required pages/items within bounded resource limits and fails without a partial
completion receipt if the provider/metadata contract changes or a limit binds.

The backend image and backend CI install the `topography` extra. The optional
libraries are imported only by the operator sample command, not at API startup.
Running this CLI inside an image is not permission to alter the production
Compose pins or publish its output.

### Encode a development artifact pair

After generating a sample, prepare a WGS-84 GeoJSON geometry file and the full
contributing-source notice text. Supply an existing renderer-3 vector pack with
the same map ID. The compiler preserves the input pack and refuses an existing
output directory:

```sh
.venv-topography/bin/map-topography --cache "$terrain_cache" encode \
  --sample "$terrain_cache/alps-a.json" \
  --selection /absolute/path/selection.geojson \
  --vector-pack /absolute/path/vector-pack \
  --map-id YOUR_MAP_ID \
  --attribution /absolute/path/complete-source-notices.txt \
  --output /absolute/path/new-development-pair
```

For a LineString, also pass `--corridor-width-m` (full width); the sample must
cover the complete buffered corridor. Polygon holes are retained. Current
compilation rejects wrapped selections; split antimeridian areas into separate
jobs. The device/iPhone renderer domain is Web Mercator, unlike the broader
acquisition catalog's polar coverage.

The output contains `device/VECTMAP/`, a separate `.btopo`, `ATTRIBUTION.txt`,
and `topography-receipt.json`. That receipt is development evidence, **not** an
authenticated catalog grant, signed map manifest, or source-license approval.

Current bounds are 256 blocks/400,000 compiled points per pair, 4,096 contour
records/65,536 points per block, 256 points per record, 512 m maximum encoded
segment, 16,384 companion tiles (both scales), and 256 MiB per companion.
Exceeding a bound rejects the result rather than silently truncating terrain.

Repeatability is qualified within the same native runtime. Cross-platform
SQLite/Pillow/PROJ byte identity has not been qualified; producer environment
locking must precede production publication.

### Local validation on 2026-09-13

- Python/C++/Swift malformed-section parity and Python/Swift companion tests.
- Polygon holes, shared block endpoints, coincident edge ownership, zero
  contours, cancellation, terrain-only blocks and non-overwriting publication.
- A real Alps sample compiled to 6 contour blocks, 427 records, 25,041 points
  and 428 companion tiles (3,080,192 bytes). This local sample used a test
  attribution digest and must not be distributed as a reviewed map.
- Native MapKit ownership tests verify contour replacement beneath route
  overlays without camera or tracking side effects.
- A dirty-tree `WAVESHARE_AMOLED_175` build passed. It is not upload-eligible,
  exact-commit CI, physical rendering evidence, or 2.06-inch qualification.

Use the [provider research prompt](research/topography-provider-research-prompt.md)
for the next source-coverage and redistribution review.

## Acquisition and reproducibility boundary

- Only exact HTTPS Copernicus object URLs constructed from canonical catalog
  names are accepted. Redirects cannot change the source or object.
- Both catalogs must match checked-in byte lengths, counts, and SHA-256 hashes.
  A changed upstream catalog fails closed; review and update the policy instead
  of automatically trusting the new catalog.
- Each TIFF is limited to 128 MiB, with bounded reads, a 20-second socket timeout,
  a 600-second acquisition deadline, cancellation checks, and a 256 MiB free-space
  reserve. Interrupted downloads never publish a receipt. Downloads restart;
  they do not implement HTTP resume or silently fall back on transport errors.
- A per-object process lock serializes publication. Content-addressed blobs and
  source-bound receipts publish atomically with file/directory synchronization.
  Reuse rejects changed bytes and malformed receipts rather than refetching them.
- Tile hashes are **locally observed on first TLS acquisition**, not provider-
  signed checksums. A pinned catalog proves tile names, not immutable raster
  bytes. Retaining the exact receipts and blobs is necessary for reproduction.
  This operator cache has no production retention, lease, or eviction service.
- The source policy is included in worker producer-input hashing. Contour
  evidence also includes source hashes and Python/native-library/platform
  identities. Repeatability is established for the same inputs and runtime;
  cross-platform byte identity is not promised.

## Contour evidence contract

`bicino-contour-evidence-v1` is sorted-key canonical JSON ending in a newline.
It uses a fixed UTM/polar projected grid and four-pixel halo, exact inverse
pixel-centre projection, bilinear resampling, serial contour
extraction, integer-millimetre points, canonical line/ring orientation, and
sorted/deduplicated records. No wall-clock timestamp or local cache path enters
its identity. Required source-review links remain attached to the evidence.

Standard mode uses 30 m pixels and 20 m / 100 m contour intervals; a processing
region containing a GLO-90 fallback uses 90 m pixels and 50 m / 250 m intervals throughout.
NaN/no-data is masked, not filled with zero. Partial no-data is measured in
millionths; an all-no-data raster is rejected. Contour records/points and elevation
range are bounded independently of input file size.

Known limitations, intentionally **not** production claims:

- geocell fallback only; no finer per-pixel 90 m gap filling or regional blending;
- small rectangular inspection bounds only; wrapped-antimeridian planning works,
  but sampling requires separate jobs on each side;
- the projected envelope/halo extends outside the requested rectangle; the
  compiler performs final polygon/corridor clipping and device budgeting;
  cross-source and cross-region seam qualification and smoothing remain pending;
- source metadata assumptions need formal review and mask validation before
  publication; `productionApproved` and `productionEligible` remain false;
- exact projection/sampling is chunked with cancellation checks; each native
  contour call is bounded but not interruptible mid-call, so production workers
  still need execution deadlines;
- no elevation labels, hillshade, qualified route contrast, MapKit coordinate
  correction, or physical firmware render qualification yet.

## Local evidence

The live samples below were generated twice with identical bytes on macOS
arm64, Python 3.11.13, rasterio 1.4.4, GDAL 3.10.3, PROJ 9.7.1, contourpy 1.3.2,
and numpy 1.26.4. All eight reported zero no-data pixels. Artifacts are local
research evidence, not distributed map packs.

| Sample bounds W/S/E/N | Grid | Contours / points | Evidence bytes | Evidence SHA-256 |
| --- | --- | ---: | ---: | --- |
| Alps `6.82 / 45.88 / 6.87 / 45.93` | 30 m | 213 / 26,422 | 619,158 | `4d0f0b821ad375e08f0cf8cf6213340640943296a1ea119052150891982cc498` |
| Singapore `103.81 / 1.34 / 103.86 / 1.39` | 30 m | 296 / 8,416 | 199,959 | `0042a075699bbb2a5ea274a4e98c5bfe4a92a90701464b77fa4185c31c54b9fe` |
| Shanghai `121.43 / 31.20 / 121.48 / 31.25` | 30 m | 33 / 307 | 10,018 | `9e70e0f088a0c685d13596aca3b698229f93a74f92e94e89ea80fb2743bcf6d7` |
| GLO-90 fallback `44.80 / 40.10 / 44.85 / 40.15` | 90 m | 30 / 1,546 | 38,368 | `f7e01e82c485034c66cccc4d05cf70cdc5f77f52b0683f2470d11edaeda56434` |
| Colorado `-105.65 / 39.55 / -105.60 / 39.60` | 30 m | 137 / 18,486 | 433,085 | `7a32e5da0c42188c930cf41f84ac1506fb5fd34902008d0e630303b196876a92` |
| Kenya `37.28 / -0.20 / 37.33 / -0.15` | 30 m | 214 / 29,067 | 680,038 | `a370dff2ec05a1d335798df5bc1817f8b5fa2fc4f9f8ec6212fb7458850d54d6` |
| Peru `-72.56 / -13.18 / -72.51 / -13.13` | 30 m | 368 / 55,020 | 1,284,180 | `35fb07decd112e40f196aec0cd82940dae0147a1f481a26c129ccbc809f33f94` |
| Svalbard `15.60 / 78.21 / 15.65 / 78.26` | 30 m | 31 / 1,145 | 29,230 | `5ba2b8760731d26f395be190ac7809d1dd60b9d65762e4a368ef8e902f79629c` |

Synthetic raster tests exercise determinism, no-data masking, invalid CRS,
oversized grids, contour complexity, negative coordinates, poles/antimeridian
planning, failed downloads, cancellation, corrupt receipts, concurrent staging,
and disabled profile gates. They do not download live provider data in CI.

Local validation: the 770-test backend suite passes with two existing Linux-
procfs tests skipped on macOS; all 55 deployment tests pass. The 24 topography
and eight generation-policy tests also pass under Python 3.10 on Linux ARM64
and AMD64 in OrbStack, with **no raster-test skips**. Minimal Linux containers
need `libexpat1` for the raster wheel; the backend image explicitly includes it.
A broken installed native dependency fails tests instead of being treated as
an absent optional extra. Full production-image, GitHub CI, and hardware gates
are separate from these local checks.

## Next end-to-end gates

1. Complete [source review](templates/topography-source-review.md), including
   exact attribution/disclaimers, retention rights, masks, and source-boundary
   quality samples. Do not treat a terms URL as a complete attribution notice.
2. Specify/golden-test FMB v5 and companion readers together, including identity,
   catalog sharing, promotion, and rejected/unsupported paths.
3. Extend the durable generation pipeline with buffered geometry, final clipping,
   packaging, progress, reuse, retention, and bounded worker execution.
4. Add firmware and iPhone decoding, display, settings, and offline lifecycle.
5. Qualify exact artifacts on both boards and representative iPhones, then use
   the existing canary/promotion workflow. No purchase checks belong in any gate.
