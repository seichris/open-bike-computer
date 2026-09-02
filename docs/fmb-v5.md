# FMB v5 Map Block Format

FMB v5 is the block format for renderer target 4. It is cumulative: the base
geometry is byte-for-byte compatible with FMB v2, extension sections 1-3 are
the FMB v3 street-label tables, section 4 is the FMB v4 building table, and
section 5 contains offline OpenStreetMap points of interest.

All multi-byte values are little-endian. Every block is limited to 2 MiB and
must consume its complete file with no trailing bytes.

## Header and base geometry

The file begins with `FMB\x05`, followed by the existing FMB v2 polygon and
polyline records. See [map-stream-format-v1.md](map-stream-format-v1.md) for the
base record layout.

## Extension directory

The base geometry is followed by one canonical `EXT5` directory:

```text
Directory header
  char[4] magic           // "EXT5"
  uint8   sectionCount    // exactly 5
  uint8[3] reserved       // zero

Directory entry, repeated in section-type order 1...5
  uint8   sectionType
  uint8   flags           // 1: critical
  uint16  reserved        // zero
  uint32  offset
  uint32  length          // nonzero
  uint32  crc32           // IEEE CRC-32 of section bytes
```

Sections are contiguous, ordered, non-overlapping, and cover every remaining
file byte. Unknown, missing, duplicated, reordered, non-critical, corrupt, or
non-contiguous sections invalidate the complete block.

Section types 1-4 retain their FMB v3/v4 definitions. Target 4 requires all
five sections even when a section has zero logical records.

## Section 5: POI profile 1

```text
POI section header (8 bytes)
  uint16 recordCount      // 0...16384
  uint16 recordSize       // exactly 8
  uint32 categoryMask     // bits 0...4; no other bits

POI record (8 bytes)
  int16  localX           // 0...4095 metres
  int16  localY           // 0...4095 metres
  uint8  category         // 1...5
  uint8  maximumZoom      // 0...5
  uint8  rank             // 0...3; lower is preferred
  uint8  flags            // zero in profile 1
```

The category mask is exactly the union of `1 << (category - 1)` for all
records. It is zero for an empty section. The section length is exactly
`8 + recordCount * 8`; trailing bytes are forbidden.

Records are sorted by local X, local Y, category, rank, maximum zoom, and
flags. Classification and canonical OSM identity are generator concerns and
are not stored in profile 1.

| Category | Code | Visibility bit | Default maximum zoom |
| --- | ---: | ---: | ---: |
| Shops | 1 | 13 | 2 |
| Restaurants & Cafes | 2 | 14 | 3 |
| Public Toilets | 3 | 15 | 3 |
| Gas Stations | 4 | 16 | 3 |
| Bicycle Shops & Repair | 5 | 17 | 3 |

## Renderer target and manifest

A target-4 signed manifest requires FMB v5 for every `.fmb` block and declares:

```json
{
  "target": {
    "renderer": "esp32-fmb",
    "formatVersion": 4,
    "labelProfileVersion": 1,
    "buildingProfileVersion": 1,
    "poiProfileVersion": 1
  }
}
```

The manifest `pois` summary contains `recordCount` plus the five category
counts. The category counts must sum to the record count and must match an
independent walk of every FMB v5 section 5.

FMB v1-v4 remain valid only for renderer targets 1-3. A reader must never treat
a malformed or newer block as an empty legacy block.
