# Elevation research: implementation and evidence

Follow-on implementation: [regional native ingestion, explicit offline datum
operations and artifact encoding](../topography-regional-ingestion.md). The
remaining-work list below records the earlier tranche; the linked document
distinguishes newly implemented engine behavior from provider qualification.
The latest extension joins up to 16 explicitly reviewed, aligned native tiles
before interpolation; gaps remain masked and overlapping editions are rejected.
Synthetic tiled/untiled equivalence is tested through device contour records;
real cross-provider seam qualification remains outstanding.

Input: the maintainer-supplied ChatGPT report and
`bicino-elevation-research-2026-09-13.zip`, SHA-256
`9142faa7f5d5acf00327f733d07752cc2eae34869247e999cc336ce3b0f9dcf8`.
The package's file checksums were verified. Its examples are research data, not
executable instructions, production approval, or permission to register accounts
or send commercial-use notifications.

## Changes implemented from the report

### Existing global pipeline

- Preserve the two pinned public Copernicus 2021 source identities. In particular,
  do not rename the existing `copernicus-glo90-2021` identity to the report's
  suggested alias and invalidate existing receipts.
- Inspect and record the actual native raster grid, pixel-registration tag,
  band units, scale/offset, declared no-data and validity-mask flags. Reject
  rotated/inverted grids, unexplained scale/offsets and unsupported units.
- Apply internal validity masks and non-finite masking before interpolation.
  Reject out-of-range **valid native** heights before interpolation can smooth
  an undeclared sentinel into apparently plausible terrain. Negative heights
  remain valid. No single Copernicus no-data number is hardcoded.
- Record unavailable water/edit/fill/quality masks explicitly. Neither a missing
  geocell nor a void is classified as ocean; lakes are never filled with zero.
- Select a fixed UTM/polar processing region, a zero-origin metric pixel lattice,
  and a four-pixel halo. Acquire the inverse-projected halo's geocells too and
  fail if they are unavailable. Include the halo in tile/pixel resource limits.
- Choose the 30 m/20 m or 90 m/50 m profile from the entire fixed region's pinned
  catalogs, including a one-degree neighbor band. A request cannot silently
  become finer just because it omits the region's coarse fallback cells.
- Sample exact pixel centres in bounded chunks, with explicit bilinear weights
  and full contributing-pixel validity. This replaces Rasterio 1.4.4's
  request-envelope-dependent approximate warp. The zero-tolerance WarpedVRT
  alternative failed in the pinned local runtime; it is not used.
- Preserve the existing single-intermediate compilation into device blocks and
  iPhone companion tiles. Changing the algorithm changes evidence identity;
  old samples/receipts remain immutable and are not silently upgraded.

Fixed-region crossing and cyclic/pole-enclosing halos currently require explicit
partitioning. This is not automatic antimeridian or cross-region seam support.
At native raster edges, centres extend only to the half-pixel footprint boundary;
cross-source residual/edge qualification is still required. A synthetic overlap
test verifies byte-identical device contour sections inside two overlapping
requests, not worldwide cross-provider seam quality.

### Regional native-asset discovery

The new `map-topography discover` command implements bounded metadata adapters:

| Adapter | Selection and preserved evidence |
| --- | --- |
| `swissalti3d-2m` | STAC 0.9 collection, returned pagination, explicit 2 m/LV95/LN02 filename contract, native TIFF, provider SHA-256 multihash. |
| `canada-hrdem-lidar` | HRDEM LiDAR collection and returned pagination; select `dtm`, never `dsm`, VRT, thumbnail or optical ArcticDEM. Retain project geometry and edition metadata. |
| `linz-national-dem-1m` | Exact national DEM collection, static item links, relative href resolution and parent-provided item checksums. Select its native TIFF `visual` asset; retain source-lineage metadata. |

Collection and item/page bytes are retained exactly, with observed SHA-256 values.
All pagination/item links must complete inside source-specific HTTPS path,
document/item/asset/byte/time budgets. A cycle, unsupported checksum, duplicate
item, malformed footprint, ambiguous asset or failed request rejects the entire
snapshot. This command does **not** download elevation rasters or claim valid-
pixel coverage, licensing approval, a completed vertical conversion, or a
production-ready regional map. LINZ's static traversal may hit the time budget;
it then fails without publishing a partial snapshot rather than claiming a
complete national inventory.

Primary metadata/docs checked on 2026-09-13:
[swisstopo collection](https://data.geo.admin.ch/api/stac/v0.9/collections/ch.swisstopo.swissalti3d),
[CanElevation documentation](https://nrcan.github.io/CanElevation/stac-dem-mosaics/),
[LINZ elevation repository](https://github.com/linz/elevation).
Their metadata conventions differ: swisstopo's generic license label is not a
license decision, Canada's DTM and DSM are separate assets, and LINZ's `visual`
key is interpreted only inside the fixed DEM collection.

### Executable qualification inventory

`topography-qualification-v1.json` records 16 source/product families, with
separate implemented-acquisition, implemented-discovery and planned stages.
`map-topography sources` validates the inventory without contacting providers.
It rejects duplicate identities, missing/cyclic fallback references, malformed
evidence digests and any attempt to mark the research inventory production-
approved. The inventory is included in producer-input hashing.

The registered CDSE 2024_1 candidate is distinct from public 2021. NASADEM's
merged integer HGT candidate is distinct from its SRTM-only floating product;
AW3D30 remains per-tile/mixed-release and records its registration and advance
commercial-notification requirement. AHN1–4 and AHN5/6 have separate entries.
US/Canadian/territorial native datums that need per-asset verification remain
unknown, not silently assigned from a country name.

All nine qualification evidence slots start null. URLs and dataset names are
review pointers, **not** reviewed license snapshots or complete notices. The
inventory is not a replacement acquisition policy, source-priority change,
vertical-transform engine, or production publication gate. The existing global
renderer-4 production disablement still enforces the release boundary.

Mainland-China publication remains disabled with distinct legal-scope and
MapKit-alignment review requirements. Merely changing the contour interval is
not approval. No approximate country rectangle, coordinate offset, or automatic
WGS84 correction was introduced. See the report's
[official public-map content rules](https://www.mfa.gov.cn/web/wjb_673085/zzjg_673183/bjhysws_674671/bhflfg/dtdmxgfl/202303/P020230313585504979937.pdf)
for the issue requiring qualified jurisdiction-specific review.

## Validation and outstanding work

- Broader Python validation completed successfully: 801 backend tests run
  (two existing macOS-inapplicable skips) and all 55 deployment tests. Three
  Swift/C++ cross-reader compilation tests were deliberately withheld. Subsequent
  discovery suffix/cancellation tests are covered by the focused rerun.
- The Python regression suite covers native masks, NaN and negative heights,
  undeclared sentinels, fixed regions, halo failure before download, region-wide
  coarse profiles, matching overlap contours, discovery pagination/checksums,
  and fail-closed qualification validation.
- The updated real Alps sample was produced twice with identical bytes:
  693,103 bytes, SHA-256
  `f6ad8ec3c34bf3508a68004b2931764ab96abcc0a623e265948dace44572d999`.
  This is local inspection evidence, not distribution approval or measured
  native-raster accuracy.
- A live small-AOI Swiss discovery completed and retained upstream metadata;
  no regional raster was downloaded. Canada/LINZ native metadata was inspected,
  and their discovery control flow is covered by synthetic fixtures; full live
  traversals are not claimed.
- After the maintainer's pause instruction, no firmware/app build, native-reader
  compilation, installation, flashing or build-triggering push is part of these
  changes. Earlier build evidence does not validate this new source revision.

The remaining work is deliberately visible: approved source notice snapshots;
pinned, reviewed vertical-transform grids and pipelines; native regional raster
acquisition/normalization and boundary QA; USGS/CDSE/NASA/JAXA and later adapters;
automatic region/wrap partitioning; and the end-to-end job, catalog, download,
settings and publication integration described in the main plan. The report's
provider inventory is not a claim that all providers are now integrated.
