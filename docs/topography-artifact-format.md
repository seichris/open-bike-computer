# Development topography artifact contracts

These are implemented codecs, not production activation approvals. Renderer 4
is still rejected by public generation, signed installation and catalog paths.
Do not infer a complete app/device feature from an accepted standalone block.

## FMB5

All multibyte values are little-endian. FMB5 retains the FMB4 base geometry and
section 1 (strings), 2 (glyph runs), 3 (labels) and 4 (buildings) payloads exactly.
Its extension directory is `EXT5`, count 5, three zero reserved bytes, followed
by five existing 16-byte critical section entries in order. Each section has a
checked offset, length and CRC32. Section 5 is required, including for zero
contours. The whole block remains limited to 2 MiB.

Section 5 starts with this 12-byte header:

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | u8 | Section version, exactly 1 |
| 1 | u8 | Reserved flags, exactly 0 |
| 2 | u16 | Minor contour interval in metres |
| 4 | u16 | Index contour interval in metres |
| 6 | u16 | Record count, at most 4,096 |
| 8 | u32 | Total point count, at most 65,536 |

Allowed interval pairs are `(20, 100)` and `(50, 250)`. Each record starts with
14 bytes: signed elevation metres (i16), flags (u8), reserved zero (u8), point
count (u16), then `minX, minY, maxX, maxY` (four i16 values). Elevations must be
within -12,000…10,000 and divisible by the minor interval.

Record flags:

- Bit 0: index contour; must exactly match divisibility by the index interval.
- Bit 1: boundary-affected geometry. The current compiler marks selection clips
  and block-edge contacts; this is not a claim of a surveyed source boundary.
- Bit 2: no-data quality caution. The current compiler conservatively marks all
  records when the source mosaic has any missing pixels.
- All other bits must be zero.

Each record contains 2–256 point pairs. The first is an absolute `(i16, i16)`;
the remaining pairs are signed deltas. Reconstructed local coordinates must
stay within 0…4,096. Consecutive points must differ and each segment must be at
most 512 metres long in the renderer's Web Mercator coordinates. Stored bounds
must equal reconstructed bounds exactly.

Records sort strictly by elevation, flags, bounds, then **encoded point bytes**.
Duplicates, descending records, trailing bytes, overflows and mismatched totals
are invalid. The geometry compiler canonicalizes line direction/ring rotation
before splitting long lines; the binary encoder sorts records, but does not
silently rewrite their point order.

The Python, allocation-free streaming C++, decoded C++ and Swift readers are
tested with refreshed-CRC semantic mutations. The Swift section reader does
not itself validate an enclosing FMB directory or signed stream.

## iPhone companion `.btopo`

This artifact contains only Bicino-generated transparent contour tiles, never
Apple base-map bytes. Its independent role is `topography-ios-v1`; it does not
belong in a device BMAP payload.

The SQLite application ID is `0x42544F50` (`BTOP`), user version 1, page size
4,096. The only schema objects are these exact tables:

```sql
CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL)
CREATE TABLE tiles (z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, scale INTEGER NOT NULL, png BLOB NOT NULL, sha256 TEXT NOT NULL, PRIMARY KEY (z, x, y, scale)) WITHOUT ROWID
```

Metadata has exactly one row, ID 1, containing sorted compact JSON with a
trailing newline. The exact fields are `schemaVersion`, `profileVersion`,
`styleId`, `tileScheme`, `tileSize`, `scales`, `minimumZoom`, `maximumZoom`,
`mapId`, `intermediateSha256`, `sourcePolicySha256`, `attributionSha256`,
`boundsE7`, and `tileCount`.

The profile fixes schema/profile 1, style `contours-transparent-20-50-v1`, XYZ
north-origin Web Mercator, 256-point tile geometry, scales `[1,2]`, zoom 9–16.
PNG tiles use RGBA and dimensions `256 * scale` on each axis. Each tile has its
own SHA-256. Both scales must exist for each tile key; entirely transparent
pairs are omitted. At most 163,840 rows, 1 MiB per PNG and 256 MiB per database
are allowed. Unknown schema objects, mismatched counts/digests/dimensions and
wrong map/intermediate bindings reject the artifact.
Companion generation also bounds contour-to-tile references at 2,500,000 before
rasterization. Tile and reference limits are independent of the file byte limit.

The iPhone reader requires a separate trusted receipt binding file bytes/SHA,
map entry, device-content receipt, map ID, intermediate, source policy and
attribution. Self-declared SQLite metadata cannot establish that trust. The
reader is actor-serialized and read-only; its PNG cache is capped at 4 MiB and
128 entries. Download grants, durable association journaling and regional
alignment eligibility are separate, still-unfinished integration layers.

Native-runtime changes can alter SQLite/PNG bytes. Repeated builds in the same
tested runtime are deterministic; cross-platform producer locking and visual
equivalence are not yet qualified.

## Experimental terrain and contour numbers (issue #527)

Development clients negotiate `target.terrainProfileVersion: 1` with renderer
format 4. Requests without that field retain the original FMB5/v1 companion
contract. The optional field participates in the map build/reuse identity.
Firmware advertises `terrain_experiments` in CAP2 bit 31 to client version 29
only in diagnostics builds. Production does not advertise or accept terrain
screen settings. Existing FMB5 contours gain numeric labels without requiring
terrain files or a new FMB version.

An experimental pair retains the FMB5 blocks and adds a same-basename `.fme`
sidecar for each covered block. FME1 is exactly 4,372 bytes:

| Offset | Content |
| --- | --- |
| 0 | ASCII `FME1` |
| 4 | Signed little-endian block X (Web Mercator / 4,096) |
| 8 | Signed little-endian block Y |
| 12 | Little-endian CRC32 of all node bytes |
| 16 | 33 × 33 nodes, X fastest, Y south to north, 128 Mercator metres apart |

A node is `i16 elevationMetres, u8 shade, u8 slopeDegrees`. Elevations are
−12,000…10,000; −32,768 means no-data and requires shade/slope zero. Slope is
0…90°. Shade is 0…255 from a fixed northwest light at 45° elevation. Derivatives
use physical ground spacing. All contributing samples must be valid; missing
pixels are never interpreted as sea level. The DEM is the same pinned surface
model/datum used by contours. Node quantization is one metre; this does not
imply one-metre source accuracy.

Generation samples globally aligned nodes plus a derivative halo. It retains
normalized grids in operator sample evidence and packages the grids with the
signed map. Grids are clipped to the same polygon/route corridor, including
holes. Block borders share nodes. Limits remain 256 blocks and existing worker
raster bounds. Sidecar bytes are included in manifest hashes, transfer totals,
atomic installation and rollback. Readers validate exact size, coordinates,
CRC and node semantics; absent sidecars leave legacy map behavior available.

Experimental `.btopo` uses SQLite user/schema version 2, with style
`contours-labels-terrain-v2`; profile version remains 1. The existing two tables
are retained, with two additional exact tables:

```sql
CREATE TABLE labels (x INTEGER NOT NULL, y INTEGER NOT NULL, elevation INTEGER NOT NULL, PRIMARY KEY (x, y, elevation)) WITHOUT ROWID
CREATE TABLE terrain (x INTEGER NOT NULL, y INTEGER NOT NULL, grid BLOB NOT NULL, PRIMARY KEY (x, y)) WITHOUT ROWID
```

Labels use integer Web Mercator metres and signed elevation metres, capped at
100,000 anchors. Terrain contains at most 256 validated FME1 blobs bound to
their X/Y primary key. The file retains its authenticated companion receipt,
byte limit and contour-tile limits. New readers support both SQLite versions;
v1 stays contour-only on iPhone. Regenerate/download an experimental pair to
obtain phone labels and terrain. No unsigned amendment to a saved companion is
accepted. The transport artifact role remains `topography-ios-v1`; the SQLite
schema, negotiated by the map request, versions its payload.

For operator fixtures, `map-topography sample --terrain ...` includes DEM grids
in sample evidence. Feed that sample to the existing `encode` command. This
produces development artifacts, not a signature or production-source approval.
