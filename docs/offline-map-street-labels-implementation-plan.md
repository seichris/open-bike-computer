# Offline Map Street Labels Implementation Plan

## Outcome

Add readable street names to offline maps on the bike computer without baking
the final visual treatment into map tiles. A downloaded map contains the road
names, localized variants, road references, shaped text runs, and candidate
label spans. Firmware chooses what to show for the active screen profile,
projects candidates through the current map transform, removes collisions,
keeps text upright, and draws the accepted labels with a fill and halo.

The result is a durable hybrid vector-label system:

- map data owns facts and expensive preprocessing;
- firmware owns appearance and last-mile layout;
- the iPhone exposes supported label choices independently for **Map** and
  **Map + Navigation**; and
- old FMB v1/v2 maps remain readable, while label-aware maps use FMB v3.

The default treatment is road-following text with an adaptive halo. Global
street-name pills are deliberately not used because they hide too much map
geometry. A future current/next-road overlay can use a pill or banner once the
navigation contract carries structured road identity; it must not change how
ordinary map labels are encoded.

This plan is associated with
[issue #127, Add street names to offline device maps](https://github.com/seichris/open-bike-computer/issues/127).

## Baseline

This plan was prepared from `origin/main` at
`e2f9d0ad76b9d15c0c24def0302d16ff4d31ff32`.

The current system already has the right broad layers but no label contract:

1. `tools/OSM_Extract` turns OSM source data into styled, clipped map blocks.
2. `map_format.py` writes FMB v2 polygon and polyline records.
3. The backend packages those files into a signed `BIKEMAP1` artifact.
4. The iPhone verifies that artifact and transfers it to the bike computer.
5. Firmware validates, atomically activates, caches, transforms, and draws map
   blocks.
6. The iPhone already manages independent Map and Map + Navigation profiles.

The missing pieces are:

- the extraction pipeline does not carry `name`, localized `name:*`, or `ref`
  through styling and clipping;
- FMB v2 has no string, shaped-run, or label-candidate sections;
- signed map packs accept only `.fmb` and `.fmp` files;
- firmware has no bounded font-pack reader or road-label layout pass;
- the one-byte `CAPS` feature mask is full; and
- the profile UI and BLE settings contract have no label controls.

## Product contract

### Default appearance

- Draw labels along sufficiently straight road spans.
- Normalize rotation so text is never upside down.
- Use an adaptive high-contrast halo selected by the firmware map theme.
- Show a balanced set of labels by default on Map; keep labels off by default
  on Map + Navigation to protect navigation glanceability.
- Prefer road names; use a route reference only when no usable name exists.
- Avoid navigation banners, controls, the position marker, and other declared
  screen occlusion regions.
- Do not repeat the same road name at visually adjacent candidates.

### User-facing settings

Expose these controls separately under **Map** and **Map + Navigation**:

| Setting | Values | Default |
| --- | --- | --- |
| Street labels | On, Off | Map: On; Map + Navigation: Off |
| Density | Major roads, Balanced, All roads | Balanced |
| Language | Local, Preferred, Local + Preferred | Local + Preferred |
| Text size | Small (18 px), Standard (22 px), Large (26 px) | Small |
| Orientation | Follow roads, Keep upright | Keep upright |

Visibility is a distinct persisted UI setting. The existing BLE density value
remains backward compatible: the app sends `0` while labels are disabled and
otherwise sends the persisted `1...3` density.

`Keep upright` draws horizontal text at the candidate midpoint. It is an
accessibility and glanceability option, not a different map download.

Halo thickness, label color, padding, collision margin, and road-class weights
are firmware theme tokens. They are intentionally not raw user settings. This
keeps the UI understandable while allowing future firmware releases to restyle
labels without regenerating every map.

### Language semantics

- **Local** selects the OSM `name` value.
- **Preferred** selects the first available requested BCP-47 language variant.
- **Local + Preferred** draws both only when they differ after Unicode
  normalization.
- The fallback chain is: exact requested tag, base language tag, local `name`,
  configured international fallback such as `name:en`/`int_name`, then `ref`.
- A pack records the ordered preferred languages used to build it. Changing
  that list requires map regeneration, but changing Local/Preferred/Bilingual
  mode does not.

The iPhone sends at most three unique, normalized BCP-47 language tags in a map
generation request. The backend preserves all `name:*` tags in the normalized
intermediate data, then includes only the requested variants plus the declared
fallbacks in the device pack. This keeps the source pipeline language-neutral
without making every downloaded map carry every translation and glyph.

### Legacy maps

FMB v1/v2 maps continue to render exactly as they do now. Label controls remain
visible but explain **Download this map again to add street names** when the
active map is legacy. A missing label asset on a legacy pack is normal. A
missing, corrupt, or mismatched label asset on a label-aware pack is an install
failure, not a silent partial activation.

## Decisions locked into this plan

1. Do not pre-render street names into raster tiles or map-block backgrounds.
2. Do not ship the complete CJK font set in firmware.
3. Do not make the ESP32 parse raw OSM tags, shape arbitrary Unicode text, or
   discover label spans from full road geometry at render time.
4. Preserve UTF-8 text and semantic variants in the map data even though text
   shaping happens during map generation.
5. Precompute multiple straight-enough candidate spans per named road and zoom
   band on the backend.
6. Perform final projection, language selection, density selection, duplicate
   suppression, collision resolution, rotation, and drawing on the ESP32.
7. Store block-local deduplicated strings and shaped runs in FMB v3. Store
   map-wide deduplicated glyph bitmaps in one signed font asset.
8. Keep FMB v1/v2 readers and fixtures indefinitely unless a separate migration
   explicitly removes them.
9. Keep the outer signed `BIKEMAP1` byte envelope and install protocol v2.
10. Introduce renderer target format 2 for packs that contain FMB v3 and the
    street-label font asset.
11. Continue producing renderer target format 1 only for explicitly legacy
    clients during rollout; do not place v3 blocks in a target-1 pack.
12. Replace the exhausted one-byte capability response with an extensible,
    versioned capability frame while retaining the old response for old apps.
13. Use bounded data structures and validate every offset, count, string, run,
    bitmap, and cross-file reference before activating a map.
14. Treat label generalization as a map-design rule, not an emergency memory
    fallback. The generator emits a deliberate density hierarchy and fails the
    build if hard resource limits cannot be met.
15. Ship the complete architecture together. Intermediate PRs may be merged
    behind compatibility gates, but no temporary raster-label or ASCII-only
    implementation becomes a product path.

## Versioning model

The implementation must keep these contracts separate:

| Contract | Existing | Label-aware | Compatibility rule |
| --- | ---: | ---: | --- |
| FMB block bytes | v1/v2 | v3 | New firmware reads v1, v2, and v3 |
| Manifest renderer target | `esp32-fmb` format 1 | `esp32-fmb` format 2 | A target-2 pack requires label-aware firmware |
| Signed map stream | `BIKEMAP1` format 1 | unchanged | Header, signature domain, and payload framing stay stable |
| Device install protocol | v2 | unchanged | Existing atomic activation and rollback remain authoritative |
| Font asset | absent | `FMA1` | Required exactly once in every target-2 pack |

The manifest can remain schema version 1 because every file still uses the
existing `path`, `bytes`, and `sha256` shape. The normative schema gains one
exact asset path for target 2:

```text
VECTMAP/<mapId>/assets/street-labels.fma
```

All other non-map extensions remain forbidden. The exact path, rather than a
general-purpose arbitrary-asset rule, makes the security boundary easy to
audit. The target object additionally records the label profile version and
ordered language tags; older consumers already reject target format 2.

## End-to-end architecture

```text
OSM PBF
  -> preserve road names, name:* variants, refs, and road identity
  -> normalize text and join compatible named road segments
  -> rank roads and generate zoom-aware straight label candidates
  -> shape each retained string with pinned HarfBuzz + FreeType inputs
  -> write FMB v3 blocks (strings, runs, semantic labels, candidates)
  -> write one map-specific FMA1 glyph pack
  -> package and sign a renderer-target-2 BIKEMAP1 artifact
  -> iPhone verifies, records label metadata, and transfers it
  -> firmware validates every block and the shared glyph pack
  -> atomic activation
  -> runtime language/density/layout/collision pass
  -> A4 glyph-mask blending into the existing RGB565 full-screen buffer
```

## Map generation request and artifact identity

Extend the iPhone/backend job request with explicit target and label data:

```json
{
  "target": {
    "renderer": "esp32-fmb",
    "rendererFormatVersion": 2,
    "firmwareVersion": "<connected-or-required-version>"
  },
  "labels": {
    "profileVersion": 1,
    "preferredLanguages": ["zh-Hant", "en"],
    "internationalFallback": "en"
  }
}
```

Requirements:

- Normalize BCP-47 tags once in the iPhone and validate them again on the
  backend.
- Permit at most three preferred tags, each at most 35 ASCII bytes.
- Include the normalized label profile in request idempotency and artifact
  reuse identity.
- Keep geographic `mapId` based on the source and selected geometry. Different
  language profiles can share a geographic map ID, while their signed manifest
  receipts and artifact object identities remain distinct.
- Record label profile version and language tags in the signed manifest.
- Include font sources, shaping dependencies, label-generator code, and config
  in `producer.buildSha256`.
- Make absent `target`/`labels` fields mean the current target-1 output only
  during the compatibility window. New app builds always request target 2.

The backend must never infer target 2 merely because a request mentions a
language. It must require the explicit renderer target so old apps cannot
accidentally receive an incompatible artifact.

## Extraction and label candidate generation

### Preserve semantic source data

Update the OSM extraction path so every road feature carries:

- `name`;
- every valid `name:*` key/value;
- `int_name` when present;
- `ref`;
- road class/type ID;
- source feature identity; and
- bridge, tunnel, layer, one-way, and junction metadata needed to avoid joining
  unrelated geometry.

`style_features` and every clip/split operation must copy this semantic label
object rather than reconstructing a style-only feature dictionary.

Normalize label text with NFC. Reject NUL, C0/C1 controls, bidi override
controls, invalid UTF-8, and values over 255 encoded bytes. Preserve ordinary
Unicode direction and combining data in the intermediate model. Emit counters
for discarded keys/values instead of silently accepting malformed text.

### Build road identity before block clipping

Join connected segments only when their normalized label variants, `ref`, road
class, layer, bridge/tunnel state, and compatible junction semantics match.
Use a deterministic source-ID tie break at ambiguous junctions. Candidate
generation happens on these joined paths before 4,096-metre block clipping, so
labels do not restart at every source segment.

Assign each candidate to one deterministic owner block based on its midpoint.
Include enough overlap metadata for the owner candidate to be considered when
the text extends across a neighboring visible block. This avoids duplicate
boundary labels without making label availability depend on load order.

### Generate candidates

For each retained road and supported zoom band:

1. simplify only for label-span analysis, never for rendered road geometry;
2. find spans whose curvature stays within a configured angular tolerance;
3. require span length to fit the longest retained text variant at the target
   size plus padding;
4. avoid junction centers and very short dead-end fragments;
5. emit multiple well-spaced candidates for long roads;
6. score candidates by road class, route reference importance, span length,
   curvature, distance from junctions, and source stability; and
7. sort all output with deterministic integer keys.

Road-class density is data, not a hardcoded list of names. Major roads receive
lower minimum zooms and stronger ranks. Local/service/path labels remain in the
pack and become eligible only when the selected density and zoom allow them.

Candidate generation must be deterministic across worker runs with identical
source, configuration, font inputs, and dependency inventories.

## FMB v3 contract

Create a normative `docs/fmb-v3.md` before landing the writer or reader. Freeze
the byte layout with shared golden fixtures consumed by Python and C++ tests.

### Base records

FMB v3 starts with `FMB\x03`. Its polygon and polyline sections retain the v2
field order and widths, including road type IDs. Existing parsing code can be
factored into shared v2/v3 routines, but old firmware still rejects v3 at the
version byte.

### Extension directory

After the polyline section, add a bounded extension directory. Every entry has
a type, flags, absolute offset, byte length, and CRC32. Sections must be unique,
sorted by type, non-overlapping, fully inside the file, and collectively account
for every byte after the directory. Unknown critical sections fail validation;
unknown non-critical sections can be skipped by a future reader.

FMB v3 requires these sections:

| Section | Purpose |
| --- | --- |
| UTF-8 strings | Block-local deduplicated names and refs |
| Shaped runs | Glyph IDs and fixed-point advances/offsets for each string and size |
| Road labels | Polyline association, variants, rank, zoom bounds, and candidate spans |

### UTF-8 string table

- Use a 16-bit string count and 16-bit byte lengths.
- Index zero is reserved for **no string**.
- Each stored string is valid NFC UTF-8, 1...255 bytes, and appears once per
  block.
- Validation applies the same control-character rules as the generator.
- The full block-local string payload is bounded independently from total file
  bytes.

### Shaped-run table

Shape text on the backend using pinned HarfBuzz and FreeType versions. A run is
keyed by string ID, language/script metadata, font face, and one of the three
supported size IDs. Each glyph entry contains a map-wide glyph ID plus signed
fixed-point x/y offset and advance. Firmware does not perform kerning, fallback
font selection, script shaping, or Unicode normalization.

Pre-shaping Latin and CJK solves the immediate requirement and leaves the wire
model capable of more scripts later. A pack build reports unsupported shaping
instead of substituting misleading text. The fallback chain can choose another
usable variant or `ref`.

### Road-label table

Each logical label record contains:

- the associated polyline index;
- stable road/class rank;
- minimum and maximum zoom;
- one or more semantic variants (`local`, BCP-47 language ID,
  `international`, or `ref`), each referencing a string and its size runs; and
- one or more candidate spans.

A candidate stores two signed block-local endpoints, a quality score, flags,
and a repeat-group ID. Endpoints are transformed by the exact same map matrix
as road geometry. The renderer derives screen midpoint, usable length, and
angle after map rotation; no geographic floating-point work is required.

### Initial hard limits

Use named constants shared by validation and decoding:

- existing FMB file limit: 2 MiB;
- strings: at most 4,096 per block;
- total UTF-8 string bytes: at most 256 KiB per block;
- label records: at most 8,192 per block;
- candidates: at most 16,384 per block;
- variants: at most 8 per label;
- glyphs in one shaped run: at most 192; and
- label extensions plus decoded indexes must fit a measured per-block PSRAM
  budget.

Phase 0 must verify these limits against dense Latin and CJK cities. Changing a
limit before the v3 spec freezes is allowed; silently allocating past the frozen
limit is not. When deliberate cartographic generalization cannot make a block
fit, fail the build with the block ID and measured counts.

## FMA1 map-specific font asset

Create one deterministic file at
`VECTMAP/<mapId>/assets/street-labels.fma`. It contains only glyphs referenced
by shaped runs in that pack.

### Font inputs

- Vendor pinned, license-compatible Noto Sans and Noto Sans CJK source font
  files under `tools/OSM_Extract/fonts/` with their license texts and expected
  SHA-256 values.
- Add that directory explicitly to the worker build-identity roots.
- Pin HarfBuzz/FreeType bindings and native packages in the worker image.
- Record font face IDs and source hashes in generation diagnostics.
- Include required attribution/license material in the repository and release
  documentation.

Do not download mutable font URLs during a map build.

### Asset layout

Define the exact bytes in `docs/fma1-font-asset.md` and shared fixtures. The
format includes:

- `FMA1` magic and format version;
- source/profile fingerprint;
- the ordered pack language table;
- sorted glyph index records keyed by map-wide glyph ID and size ID;
- bearings, advance, width, height, and bitmap offsets;
- 4-bit alpha fill masks; and
- bounded 4-bit exterior-distance masks generated from the same glyph outline.

Bitmap payloads use one deterministic, bounded RLE encoding. Firmware chooses
halo radius and opacity by thresholding the exterior-distance mask, so halo
styling remains a runtime theme choice. The index is loaded once; bitmap bodies
are read on demand into a fixed-size LRU glyph cache. The renderer never loads
the whole CJK asset into RAM.

Initial limits are:

- three raster sizes;
- at most 8,192 distinct map glyph IDs;
- at most 24,576 glyph/size records;
- at most 16 MiB for the font asset;
- at most 512 KiB for the runtime glyph bitmap cache; and
- a scratch buffer sized from the validated maximum glyph dimensions, never
  from an unchecked asset value.

The signed manifest hash protects the complete asset. The FMA reader still
validates magic, version, sorted unique keys, counts, offsets, dimensions,
encoded lengths, complete RLE consumption, language metadata, and profile
fingerprint before activation.

## Signed pack, transfer, and activation changes

### Backend

- Package exactly one `.fma` asset for target-2 maps.
- Keep `.fmb` preferred over a redundant `.fmp` with the same stem.
- Permit `.fma` only at the exact asset path and only for renderer target 2.
- Apply the 2-MiB size limit to each map block and the separate 16-MiB limit to
  the font asset.
- Require at least one FMB v3 block and reject mixed FMB v2/v3 blocks in one
  target-2 pack.
- Reject a target-1 pack containing FMB v3 or `.fma`.
- Include the font asset in file sorting, payload sizing, hashing, signing, and
  artifact identity.

### iPhone verification

- Accept target formats 1 and 2.
- For target 1, preserve the current `.fmb`/`.fmp` rules.
- For target 2, require the exact `.fma` asset, validate its role-specific byte
  limit, and reject all other extensions/paths.
- Persist the verified target version, label profile, languages, and manifest
  receipt with the downloaded-map inventory.
- Refuse transfer to firmware that did not advertise label-aware target-2 map
  support.

### Firmware stream and installer

- Extend both streaming and staged-install parsers; neither path may bypass the
  new rules.
- Dispatch files to the FMB validator or FMA validator by their exact validated
  role.
- Cross-check that every v3 run glyph ID exists in the FMA index and that every
  block/profile fingerprint matches the asset.
- Complete all validation in the inactive root before switching active-map
  metadata.
- Store renderer target, label profile version, language summary, and asset
  fingerprint in active-map metadata and renderer-validation receipts.
- Preserve the current transaction recovery, rollback, and signed receipt
  checks.
- On a post-activation renderer failure, restore the previous map exactly as
  the current workflow does.

The outer `BIKEMAP1` header, signature envelope, signing domain, file hashing,
payload order, maximum total payload, and install protocol version do not
change.

## Firmware data model and renderer

### Parsing and cache ownership

Extend `MapBlock` with label strings, shaped runs, semantic label records, and
candidates allocated in PSRAM. Store offsets/indexes instead of duplicating
strings in every record. Unloading a map block releases all of its label data.

Add one active-map `MapFontAsset` owner with:

- the validated on-disk path and fingerprint;
- language/profile metadata;
- a bounded glyph index; and
- the fixed-budget glyph bitmap LRU.

An FMB v1/v2 block has an empty label collection and follows the old rendering
path. Label-disabled mode must avoid shaped-run lookup, collision layout, and
glyph I/O.

### Layout pass

Run labels after base polygons and roads, before dynamic route/position/UI
overlays that must remain visually dominant.

For every redraw:

1. gather eligible candidates from visible blocks using zoom, density, road
   visibility, and screen profile;
2. select one or two text variants using the active language mode;
3. transform candidate endpoints with the road transform;
4. measure the shaped run from stored advances at the selected size;
5. reject spans that are clipped, too short, too steep for the chosen mode, or
   hidden by reserved UI regions;
6. normalize road-following angles to the readable `[-90°, +90°]` range;
7. stable-sort by semantic rank, candidate quality, distance to viewport
   center, and deterministic block/record keys;
8. suppress nearby repeats of the same normalized label/repeat group;
9. accept labels whose padded oriented rectangles do not intersect an accepted
   label or reserved region; and
10. derive halo coverage from the distance mask, then draw halo and fill into
    the existing RGB565 full-screen buffer.

Use oriented-rectangle collision tests rather than axis-aligned boxes so a
rotated map does not unnecessarily lose most labels. Cap work before sorting
with bounded rank buckets, then cap accepted labels at 96 per frame.

### Rendering details

- Use integer/fixed-point math in the inner loop.
- Render pre-shaped glyphs along one straight baseline; do not rotate a large
  temporary whole-string bitmap.
- Cache decoded glyph masks by asset fingerprint, glyph ID, and size ID.
- Flip glyph order/baseline direction as a unit when the road would read upside
  down.
- Draw bilingual variants as two parallel baselines with one collision box.
- Derive fill/halo colors from the current map theme and screen profile.
- Preserve the existing full-screen buffer and `full_refresh` display strategy.
- Check the existing map-render interruption hook while gathering, sorting, and
  drawing so screen changes remain responsive.
- Quantize viewport/rotation inputs for a short-lived accepted-layout cache;
  invalidate it on block set, zoom, rotation bucket, profile, language, font,
  or reserved-region changes.

### Failure behavior

- A corrupt v3 block or FMA asset never activates.
- A read error after activation stops label drawing for that frame, reports a
  typed diagnostic, and preserves the base map; repeated asset failures mark
  the active map unhealthy and enter the existing rollback/recovery path.
- A missing glyph selects the next validated text fallback. If none exists,
  omit that label; never draw uninitialized bitmap data.
- Resource-limit failures are deterministic and observable. Do not fall back to
  unbounded heap allocation.

## BLE capability and settings protocol

All eight bits in the existing `CAPS` response are assigned. Do not reuse one.

### Extensible capability response

For app client version 10 and later, introduce `CAP2`:

```text
[magic "CAP2":4][schema:1][featureFlags:u32le][TLVs...]
TLV = [type:u8][length:u8][value:length]
```

- Assign street-label profiles a new 32-bit feature flag.
- Carry the version 7...9 bird's-eye capabilities forward as feature flags
  `9...11` in `CAP2`.
- Carry the existing optional power-button configuration as a documented TLV.
- Require TLVs to be unique, length-bounded, and safely skippable when unknown.
- Keep the total response under the authenticated notification transport limit.
- New apps accept both legacy `CAPS` and `CAP2`.
- New firmware returns legacy `CAPS` to old client versions and `CAP2` to client
  version 10+ so versions 7...9 retain the bird's-eye extended-byte contract.
- Old firmware continues returning `CAPS`; the new app then hides/disables
  label-only actions and requests legacy maps when necessary.

Document both frames and golden vectors in `docs/ble-protocol.md`.

### Profile setting IDs

Retain the existing five-byte map-setting payload. Reserve these IDs:

| ID | Profile | Value |
| ---: | --- | --- |
| 27 | Map | label density 0...3 |
| 28 | Map | language mode 0...2 |
| 29 | Map | text size 0...2 |
| 30 | Map | orientation 0...1 |
| 31 | Map + Navigation | label density 0...3 |
| 32 | Map + Navigation | language mode 0...2 |
| 33 | Map + Navigation | text size 0...2 |
| 34 | Map + Navigation | orientation 0...1 |

Add shared constants, clamps, NVS keys, migration defaults, connection-level
send tracking, and iPhone `UserDefaults` keys. Label settings are sent only
after `CAP2` negotiation advertises support. Legacy firmware never receives
unknown setting IDs.

### Active-map label status

Extend the existing chunkable map-transfer status JSON with bounded fields for:

- active renderer target format;
- label profile version;
- active label languages; and
- whether the FMA asset is healthy.

The iPhone associates this with active map ID and manifest receipt. That lets
Settings distinguish **firmware does not support labels**, **map needs to be
downloaded again**, and **labels are available but turned off** without guessing
from a local download alone.

## iPhone UI behavior

Add a **Street Labels** subsection inside each existing map-style editor, with
a visibility switch above the density, language, size, and orientation controls.

- Capability unavailable: show current map controls without label controls.
- Firmware supports labels but active map is v1/v2: show the controls disabled
  with **Download this map again to add street names** and an action that starts
  the ordinary regeneration flow for the same area.
- Target-2 map active: enable all four controls and send the relevant profile.
- A preferred or bilingual mode names the languages embedded in the active
  pack, for example **Preferred — English**.
- If the iPhone's preferred language list no longer matches the pack, show
  **Update map languages**; regeneration uses the existing geographic
  selection rather than mutating the installed pack.
- Preview copy explains that Follow roads and Keep upright are device rendering
  choices, so no new download is needed.

Do not expose font-family selection, color pickers, arbitrary text sizes, raw
collision padding, or raw priority weights in the first UI. The underlying
versioned theme/profile model can add curated choices later without changing
map data.

## Observability and performance gates

### Build diagnostics

Record these values in structured job phase metadata and logs:

- named roads read, preserved, joined, and clipped;
- localized variants by normalized language tag;
- rejected/trimmed text counts by reason;
- candidates emitted by road class and zoom band;
- block string/run/label/candidate bytes and maxima;
- distinct glyphs and glyph/size records;
- font-asset bytes and compression ratio;
- shaping failures and selected fallbacks; and
- time spent in normalization, candidate generation, shaping, FMB writing,
  font writing, packaging, and signing.

Add these phases to the backend's existing `phaseTimings` contract without
removing or renaming current phases.

### Device diagnostics

In debug/validation builds record:

- candidates gathered, rejected by reason, collision-tested, and accepted;
- duplicate suppressions;
- glyph-cache hit/miss/eviction counts;
- label layout and draw duration;
- peak decoded label bytes per block and glyph-cache bytes; and
- typed FMB/FMA validation failures.

Do not log street-name text or raw OSM identifiers in ordinary production logs.

### Release gates

Phase 0 records the current label-disabled baseline on both supported hardware
targets, then freezes absolute budgets. The implementation must at minimum
meet all of these relative gates:

- label density Off changes p95 map-render time by no more than 5%;
- Balanced label layout plus drawing adds no more than 35 ms p95 and 60 ms max
  on the slower supported target in the dense-city fixture;
- peak incremental label PSRAM stays within 2 MiB, including decoded block
  indexes, glyph index, cache, collision state, and scratch buffers;
- the glyph cache never exceeds 512 KiB;
- no map block exceeds 2 MiB and no font asset exceeds 16 MiB;
- interrupted renders yield through the existing screen-cycle hook within the
  current measured responsiveness budget; and
- repeated pan/rotate redraws for 10 minutes show no growth in free-heap loss.

If hardware measurements show a stated absolute timing is unrealistic, update
this plan/spec with measured evidence before implementation is declared done;
do not remove the bounded-latency requirement.

## Implementation sequence

Each step lands production-quality foundations for the final architecture. A
feature gate stays off until all acceptance gates pass.

### Phase 0: fixtures and measured budgets

1. Capture current renderer timing, heap/PSRAM, block sizes, and interaction
   responsiveness on both Waveshare targets.
2. Build small golden extracts for Latin, accented Latin, Traditional Chinese,
   Simplified Chinese, Japanese, boundary-crossing roads, dense intersections,
   and unnamed roads with `ref`.
3. Add legacy FMB v1/v2 fixtures and malformed corpus cases.
4. Run candidate/font-size simulations for the current-location area and dense
   cities; confirm or revise the frozen hard limits with evidence.

Exit gate: fixtures are checked in, budgets are recorded, and the v3/FMA1 specs
can be frozen without guessing at field widths or supported counts.

### Phase 1: normative contracts and shared vectors

1. Add `docs/fmb-v3.md` and `docs/fma1-font-asset.md`.
2. Update the signed stream and BLE protocol docs.
3. Add canonical binary fixtures, manifest fixtures, and `CAP2` vectors used by
   Python, Swift, and C++ tests.
4. Add version/feature constants without enabling target-2 generation.

Exit gate: every consumer agrees on bytes, limits, enums, fallback semantics,
and compatibility behavior.

### Phase 2: extractor, shaping, and deterministic writers

1. Preserve and normalize semantic label tags through the full extraction
   pipeline.
2. Add road joining, ranking, and candidate generation.
3. Add pinned font inputs, shaping, subset collection, and FMA1 writing.
4. Add FMB v3 sections and deterministic writers.
5. Add extractor unit, golden, determinism, and resource-limit tests.

Exit gate: two identical builds are byte-for-byte identical; all representative
fixtures have expected strings, runs, candidates, and glyphs; over-limit builds
fail clearly.

### Phase 3: validators, packaging, and backend API

1. Add FMB v3 and FMA1 streaming validators to firmware host tests first.
2. Extend backend manifest, stream, artifact, reuse, identity, and request
   validation for target 2.
3. Extend Swift artifact verification with identical path/size/target rules.
4. Extend both firmware install paths and cross-file validation.
5. Keep target-2 publication disabled in production with the fail-closed
   `MAP_PLATFORM_LABEL_TARGET2_ENABLED=0` default. Enable it explicitly only
   in hardware-validation and approved rollout environments.

Exit gate: corrupted data is rejected consistently before activation by the
backend fixture verifier, iPhone, and firmware, while every legacy fixture still
passes.

### Phase 4: firmware rendering

1. Decode v3 label sections into bounded map-block data structures.
2. Add FMA index loading and the glyph LRU.
3. Add language selection, candidate gathering, stable ranking, repeat
   suppression, oriented collision layout, and reserved-region handling.
4. Add fixed-point halo/fill rendering and layout caching.
5. Add host algorithm/golden framebuffer tests and device instrumentation.

Exit gate: Latin/CJK labels, rotation, collision, zoom, fallback, bilingual
layout, cache invalidation, and interrupted renders pass; label Off remains at
baseline behavior.

### Phase 5: extensible capability negotiation and profile UI

1. Implement `CAP2` on firmware and iPhone while preserving `CAPS`.
2. Add setting IDs 27...34, NVS/UserDefaults persistence, and profile sync.
3. Add active-map label metadata to chunked status.
4. Add the two Street Labels settings sections and regeneration affordances.
5. Add Swift and C++ protocol, migration, downgrade, and UI-state tests.

Exit gate: every app/firmware compatibility pairing behaves intentionally and
unknown settings are never sent to old firmware.

### Phase 6: end-to-end and physical validation

1. Generate a target-2 map centered on the tester's current GPS location.
2. Verify the signed artifact, transfer it through the production path, and
   confirm atomic activation.
3. Exercise every label setting on both supported Waveshare devices.
4. Validate a Latin/diacritics map and a CJK map at multiple zooms and map
   rotations, including roads crossing block boundaries.
5. Run performance, endurance, power-cycle, interrupted-transfer, corrupt-pack,
   and rollback tests.
6. Capture dated photos/screenshots, logs, artifact receipts, firmware/app build
   identities, and measured budgets in the hardware validation report.

Exit gate: all issue acceptance criteria and the resource gates pass on both
hardware targets. A successful simulator/host run is not a substitute.

### Phase 7: production rollout

1. Release label-aware firmware that can still read legacy packs.
2. Release the iPhone app with target-2 verification, `CAP2`, settings, and
   regeneration UX.
3. Promote the label-aware worker image by immutable digest through the normal
   backend PR and hardware-gated rollout process.
4. Enable target-2 generation only for app/firmware identities that passed the
   rollout gates.
5. Observe build failures, artifact sizes, validation failures, transfer
   failures, activation rollbacks, and device render budgets.
6. Make target 2 the default for current clients only after the monitored
   cohort is healthy. Keep explicit target-1 generation for the documented
   compatibility window.

No production worker is manually replaced outside the digest-pinned promotion
workflow.

## Test matrix

### Extractor/backend

- all `name`, valid `name:*`, and `ref` data survives styling and clipping;
- invalid/control-bearing/oversized strings are rejected deterministically;
- exact/base/local/international/ref fallback ordering;
- connected same-name segments join, incompatible layer/junction segments do
  not;
- block-boundary candidate ownership and repeat groups;
- stable rank/candidate ordering across hash seeds and repeated builds;
- valid FMB v3/FMA1 generation and cross-file references;
- hard-limit failures with block/asset diagnostics;
- language profile included in reuse and signed artifact identity;
- target-1 cannot contain v3/FMA1 and target-2 requires both;
- exact safe FMA path only; traversal, hidden, duplicate, oversized, and unknown
  assets rejected;
- redundant `.fmp` removal does not remove the FMA asset; and
- producer build identity changes when fonts, shaping dependencies, config, or
  label code changes.

### Firmware host tests

- v1/v2 blocks still validate and render;
- v3 directory ordering, overlap, truncation, CRC, count, offset, and trailing
  byte failures;
- invalid UTF-8/NFC/control data and invalid references;
- FMA header/index/RLE/bitmap bounds and missing glyphs;
- cross-file profile and glyph-reference mismatch;
- exact target/path/size rules in streaming and staged installers;
- atomic activation and rollback with a font-asset failure;
- angle normalization around `-180...180`, including upside-down roads;
- stable priority and duplicate suppression across block load order;
- oriented collisions and reserved UI rectangles;
- bilingual single-line deduplication and two-line layout;
- glyph-cache eviction and deterministic memory ceilings;
- render interruption and label-disabled fast path; and
- `CAPS`/`CAP2`, TLV, setting clamp, persistence, and downgrade vectors.

### iPhone tests

- target-1 and target-2 signed artifact validation;
- FMA role/path/size and label metadata parsing;
- generation request BCP-47 normalization and limits;
- compatibility gate before transfer;
- active-map receipt and label-status association;
- legacy-map, unhealthy-asset, disabled-label, and available-label UI states;
- independent profile persistence and sends for IDs 27...34;
- old `CAPS`, new `CAP2`, unknown TLV, malformed frame, reconnect, and firmware
  downgrade behavior;
- map regeneration preserves geometry and changes the language profile; and
- UI accessibility labels and Dynamic Type behavior in Settings.

### Physical devices

Test both `WAVESHARE_AMOLED_175` and `WAVESHARE_AMOLED_206` with:

- current-location map;
- dense Latin map with diacritics;
- dense CJK map;
- north-up and course-up rotation;
- every density, size, language, and orientation choice;
- route active/inactive and Map/Map + Navigation screens;
- SD cold load, warm glyph cache, power cycle, and ten-minute redraw endurance;
- interrupted transfer, corrupt asset, renderer rejection, and rollback; and
- legacy FMB v1/v2 map after the new firmware is installed.

Before executing device work, identify which physical board is connected as
required by the repository hardware instructions.

## Acceptance criteria

The work is complete only when all of the following are true:

- OSM `name`, localized `name:*`, and `ref` survive the normalized extraction
  stage.
- FMB v3 has bounded, deduplicated UTF-8 strings, shaped runs, semantic road
  labels, and deterministic candidate spans.
- A signed, map-specific FMA1 asset supplies every referenced Latin/CJK glyph
  without embedding a complete CJK font in firmware.
- Firmware reads FMB v1/v2/v3 and renders v1/v2 maps unchanged.
- Target-2 packs are accepted only when their v3 blocks and required FMA1 asset
  pass structural, role, hash, and cross-file validation.
- Street labels respect zoom, road visibility, density, priority, rotation,
  readability, duplicate suppression, collision, and reserved UI regions.
- Text remains upright in road-following mode; Keep upright works without map
  regeneration.
- Local, Preferred, and Local + Preferred follow the documented fallback chain
  and render required Latin/CJK fixtures.
- Map and Map + Navigation retain independent persisted label profiles.
- New apps/firmware negotiate labels through `CAP2`; every legacy pairing has a
  tested, intentional fallback.
- A legacy active map produces a clear regeneration affordance rather than an
  error or false promise.
- Label Off meets the baseline regression gate and Balanced meets all timing,
  memory, file-size, endurance, and interruption gates.
- A freshly regenerated current-location map visibly shows correct nearby
  street names on each supported physical device.
- Production enablement follows the signed, digest-pinned, hardware-gated
  rollout and has an observed rollback path.

## Expected code and documentation touchpoints

### Extractor and fonts

- `tools/OSM_Extract/conf/conf_extract.yaml`
- `tools/OSM_Extract/scripts/pbf_to_geojson.sh`
- `tools/OSM_Extract/scripts/funcs.py`
- `tools/OSM_Extract/scripts/extract_features.py`
- `tools/OSM_Extract/scripts/map_format.py`
- new candidate, shaping, font-asset, and format-validation modules
- new `tools/OSM_Extract/fonts/` pinned inputs and licenses

### Backend

- `map-platform/backend/map_platform/jobs.py`
- `map-platform/backend/map_platform/pipeline.py`
- `map-platform/backend/map_platform/manifest.py`
- `map-platform/backend/map_platform/map_stream.py`
- `map-platform/backend/map_platform/reuse.py`
- `map-platform/backend/map_platform/map_stream_build_identity.py`
- backend API, worker, manifest, stream, pipeline, reuse, and fixture tests

### Firmware

- `esp32/lib/maps/src/mapBlockFormat.*`
- `esp32/lib/maps/src/maps.*`
- new FMA validator/reader, label layout, glyph cache, and mask renderer modules
- `esp32/lib/map_transfer/map_stream_parser.*`
- `esp32/lib/map_transfer/map_stream_install.*`
- `esp32/lib/map_transfer/map_transfer.*`
- `esp32/lib/ble_navigation/ble_navigation.*`
- `esp32/lib/ble_navigation/map_profile_protocol.hpp`
- `esp32/lib/ble_navigation/map_profile_persistence.hpp`
- firmware host and renderer tests under `esp32/tools/tests/`

### iPhone app

- `ios-app/BikeComputer/BikeComputer/Models/OfflineMapPlatform.swift`
- `ios-app/BikeComputer/BikeComputer/Models/BikeMapStreamFormat.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/OfflineMapManager.swift`
- `ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift`
- `ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift`
- `ios-app/BikeComputerTests/NavigationProtocolTests.swift`
- focused map-artifact, request, settings, compatibility, and UI-state tests

### Normative docs and operations

- new `docs/fmb-v3.md`
- new `docs/fma1-font-asset.md`
- `docs/map-stream-format-v1.md`
- `docs/ble-protocol.md`
- `docs/offline-map-build-and-sd-install.md`
- `docs/map-stream-rollout-runbook.md`
- hardware validation report and release notes
