# FMB v6 and FPI1 Nearby POI formats

This is the development contract for renderer target 5. It extends, and does
not redefine, [FMB v5 contour section 5](topography-artifact-format.md).
The POI contract previously proposed for FMB v5 conflicted with that deployed
contour assignment and is invalid. All multibyte integers below are little
endian. A block is at most 2 MiB.

## FMB v6

The first four bytes are `FMB\x06`. Base polygons and polylines retain FMB v2
encoding. The base is followed by one `EXT6` directory: the four-byte magic,
section count 6, three zero reserved bytes, then six 16-byte entries in section
type order. Each entry contains its type (1–6), critical flag 1, zero u16
reserved field, u32 offset, u32 length, and IEEE CRC-32 of the section bytes.
Sections are nonempty byte ranges, contiguous, ordered and consume the file
exactly. Section types 1–4 retain their FMB v3/v4 definitions; section 5 keeps
the contour codec. Section 6 is required even when it has zero records.

Section 6 begins with an eight-byte header: u16 record count (0–16,384), u16
record size (exactly 8), and u32 category mask (only bits 0–4). It is followed
by exactly `recordCount` eight-byte records:

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | i16 | Block-local Web Mercator X, 0–4095 metres |
| 2 | i16 | Block-local Web Mercator Y, 0–4095 metres |
| 4 | u8 | Category code, 1–5 |
| 5 | u8 | Maximum ordinary-map zoom, 0–5 |
| 6 | u8 | Selection rank, 0–3 |
| 7 | u8 | Reserved flags, zero |

The section length is exactly `8 + 8 * recordCount`. Its mask equals the
union of `1 << (category - 1)` over its records, or zero for an empty section.
Records sort by local X, local Y, category, rank, maximum zoom and flags. Any
CRC, size, order, range or reserved-field mismatch rejects the whole block.

| Category | Code | Visibility bit |
| --- | ---: | ---: |
| Shops | 1 | 14 |
| Restaurants & Cafes | 2 | 15 |
| Public Toilets | 3 | 16 |
| Gas Stations | 4 | 17 |
| Bicycle Shops & Repair | 5 | 18 |

Specialized bicycle POIs take precedence over generic `shop=*`, and each OSM
object belongs to at most one category. Area-derived POIs use a deterministic
interior representative point before block assignment. Category choices are
display controls; they do not alter the signed map bytes.

## Signed FPI1 Nearby index

A target-5 map includes exactly one file at
`VECTMAP/<mapId>/assets/nearby-pois.fpi`. It is a block-summary index, not a
second point database. POI coordinates remain in FMB section 6. Its bytes and
SHA-256 are covered by the signed BMAP manifest. The index is at most 524,304
bytes and has at most 16,384 entries.

The 16-byte header contains `FPI1`, u16 entry size 32, zero u16 reserved,
u32 entry count, and IEEE CRC-32 over the entry table only. The file length is
exactly `16 + 32 * entryCount`. Each 32-byte entry contains:

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | i32 | Block-grid X (multiply by 4096 for Mercator origin) |
| 4 | i32 | Block-grid Y |
| 8 | u32 | Category mask, bits 0–4 |
| 12 | five u16 | Category counts in code order |
| 22 | u32 | FMB section-6 byte offset |
| 26 | u32 | FMB section-6 byte length |
| 30 | u16 | Reserved, zero |

Entries are strictly lexicographically ordered by `(blockX, blockY)` with no
duplicates. Every nonempty POI block has exactly one entry, and empty blocks
have none. Counts total 1–16,384 per entry; nonzero counts determine the mask;
length is `8 + 8 * total`; offset/length fit within the matching signed FMB
file. Grid coordinates resolve through the canonical signed map-block path,
never through a path stored in FPI1. Producers and the independent backend,
iPhone and device installer validators must compare each entry against the
referenced block and reconcile category totals with the manifest. A missing,
corrupt, incomplete or signed-but-inconsistent index is not an empty-result
fallback.

## Target-5 manifest and layers

Target 5 requires label, building, POI and index profile version 1. Its sorted
`requestedFeatures` are either `3d-buildings`, `map-pois`, `street-labels`, or
those three plus `contours`. `layers.contours` is `included` or `not-included`
accordingly. Both variants contain section 5; the no-elevation variant uses
only the canonical empty contour section and has no topography metadata or
iPhone companion. The included variant keeps the target-4 topography source
and companion requirements. In either variant, `pois` gives total records and
the five category counts, which must match the blocks and FPI1.

Target 5 also requires signed `nearbyCoverage` with `profileVersion: 1`,
`blockSizeMeters: 4096`, and `blocks`: a nonempty, strictly lexicographically
ordered array of `[x, y]` signed block-grid coordinates. The array has at most
1,024 entries and each coordinate is within `-4893...4893`. It is the exact
complete-block selection used by extraction, including selected blocks that
emitted no FMB because they had no rendered features. Every FMB block must be
in this set. The FPI1 index is deliberately sparse and must never be used to
infer coverage. Polygon holes and route corridors therefore remain holes in
the selected block set rather than being filled by the bounding box. Firmware
warns when the rider's Nearby search circle could reach a block outside this
signed selection; it only says no matching places within the radius when the
circle is fully covered. Search results always remain limited to the
downloaded map, never an online POI lookup.

FMB v1–v5 and renderer targets 1–4 retain their existing interpretations.
Readers must not treat an unsupported or malformed newer block as an empty
legacy block. The indexed Nearby search and all POI visibility controls remain
gated by negotiated firmware capability and a healthy active target-5 map.
