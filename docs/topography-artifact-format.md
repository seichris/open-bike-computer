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
