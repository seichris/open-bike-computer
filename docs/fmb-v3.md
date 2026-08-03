# FMB v3 Binary Map Block Format

FMB v3 extends the existing typed FMB v2 block with deterministic road-label
sections. All integers are little-endian. Signed integers use two's-complement.
Files remain bounded by 2 MiB and must contain no undeclared or trailing bytes.

## Base map records

The file begins with `FMB\x03`. Polygon and polyline sections have the exact v2
layout documented by the existing reader:

```text
magic                       4 bytes
polygonCount                u16
polygon[polygonCount]
  color                     u16 RGB565
  maxZoom                   u8
  typeId                    u8
  bbox                      4 * i16
  pointCount                u16
  points                    pointCount * (i16 x, i16 y)
polylineCount               u16
polyline[polylineCount]
  color                     u16 RGB565
  width                     u8
  maxZoom                   u8
  typeId                    u8
  bbox                      4 * i16
  pointCount                u16
  points                    pointCount * (i16 x, i16 y)
```

Coordinates are projected metres relative to the block origin.

## Extension directory

The v2-compatible base is followed immediately by:

```text
magic                       4 bytes = "EXT3"
sectionCount                u8 = 3
reserved                    3 bytes = 0
entries                     sectionCount * 16 bytes
```

Each directory entry is:

```text
type                        u8
flags                       u8; bit 0 means critical
reserved                    u16 = 0
absoluteOffset              u32
byteLength                  u32
crc32                       u32, IEEE CRC-32 of section bytes
```

Entries are sorted by type, unique, non-overlapping, and contiguous after the
directory. Every byte after the directory belongs to exactly one section.
Unknown critical sections are invalid. This version has three required
critical sections:

| Type | Section |
| ---: | --- |
| 1 | UTF-8 string table |
| 2 | Shaped-run table |
| 3 | Road-label table |

## Type 1: UTF-8 strings

```text
stringCount                 u16, maximum 4,096
strings[stringCount]
  byteLength                u16, 1...255
  utf8                      byteLength bytes
```

String IDs are one-based; zero means no string. Strings are unique within the
block, valid NFC UTF-8, and contain no NUL, C0/C1 controls, surrogate code
points, or bidi override controls. Total string bodies are at most 256 KiB.

## Type 2: shaped runs

```text
runCount                    u16, maximum 12,288
runs[runCount]
  stringId                  u16
  sizeId                    u8; 0=18px, 1=22px, 2=26px
  glyphCount                u8; 1...192
  glyphs[glyphCount]
    glyphId                 u16; one-based FMA1 map glyph ID
    xOffset26_6             i16
    yOffset26_6             i16
    xAdvance26_6            i16
```

Run IDs are one-based. For every referenced string the writer emits one run per
supported size. HarfBuzz produces the fixed-point metrics during map
generation; firmware does not shape text.

## Type 3: road labels

The section starts with the shared FMA1 profile fingerprint:

```text
profileFingerprint          u32
labelCount                  u16, maximum 8,192
```

Each label is:

```text
polylineIndex               u16
rank                        u8; 0 is highest priority
minZoom                     u8
maxZoom                     u8
repeatGroup                 u16, non-zero
variantCount                u8; 1...8
candidateCount              u8; 1...255
variants[variantCount]
candidates[candidateCount]
```

Each variant is 10 bytes:

```text
kind                        u8; 0=local, 1=preferred, 2=international, 3=ref
languageId                  u8; 0=none/local, 1...N=FMA language, 255=international
stringId                    u16
smallRunId                  u16
standardRunId               u16
largeRunId                  u16
```

Each candidate is 10 bytes:

```text
startX, startY              2 * i16
endX, endY                  2 * i16
quality                     u8; higher is better
flags                       u8; zero in v3
```

Candidate endpoints use the same block-local coordinate space and transform as
the associated road. Total candidates are at most 16,384 per block. The
polyline, string, run, language, and glyph references must all resolve before a
target-2 map can activate.

## Compatibility

- FMB v1 has untyped base geometry and no extensions.
- FMB v2 has typed base geometry and no extensions.
- FMB v3 has typed base geometry and the three required label sections.
- Label-aware firmware reads all three versions.
- Legacy firmware rejects v3 at the version byte and must never receive a
  renderer-target-2 pack.
