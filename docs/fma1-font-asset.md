# FMA1 Map Font Asset Format

FMA1 stores the map-specific glyph subset referenced by FMB v3/v4 blocks. A
renderer-target-2 map contains exactly one signed asset at:

```text
VECTMAP/<mapId>/assets/street-labels.fma
```

All integers are little-endian. The file is at most 16 MiB.

## Header

The fixed header is 32 bytes:

```text
magic                       4 bytes = "FMA1"
version                     u8 = 1
sizeCount                   u8 = 3
languageCount               u8 = 0...3
faceCount                   u8, non-zero
profileFingerprint          u32
glyphRecordCount            u32, maximum 24,576
languageTableBytes          u32
faceTableBytes              u32
glyphIndexBytes             u32 = glyphRecordCount * 32
bitmapPayloadBytes          u32
```

The complete file length equals the header and all declared tables/payloads.
The profile fingerprint is the first little-endian 32 bits of SHA-256 over the
canonical shaping profile: format, supported sizes, language list, face IDs,
collection indexes, names, and full font SHA-256 values.

## Language table

Languages are ordered exactly as requested by the signed map profile. Each is:

```text
byteLength                  u8, 1...35
normalizedBCP47             byteLength ASCII bytes
```

Tags are unique and canonical (`zh-Hant`, `en-US`, and so on).

## Face table

Each face is:

```text
faceId                      u8, unique
collectionIndex             u8
nameBytes                   u16, 1...255
fontSha256                  32 raw bytes
name                        nameBytes ASCII bytes
```

Face metadata lets diagnostics identify the exact shaping/raster inputs. The
device does not need the source fonts.

## Glyph index

Records are sorted by `(glyphId, sizeId)` and are exactly 32 bytes:

```text
glyphId                     u16, one-based map-wide ID
faceId                      u8
sizeId                      u8; 0=18px, 1=22px, 2=26px
bearingX                    i16, pixels including halo padding
bearingY                    i16, pixels including halo padding
advance26_6                 i16
width                       u16, 1...96
height                      u16, 1...96
reserved                    u16 = 0
fillOffset                  u32, relative to bitmap payload
fillLength                  u32
distanceOffset              u32, relative to bitmap payload
distanceLength              u32
```

Every map glyph ID has exactly one record for each supported size. Ranges are
non-empty, in-bounds, and contiguous in glyph-index order: each record stores
fill followed by distance. This canonical layout permits single-pass bounded
validation and rejects ambiguous payload aliases.

## Bitmap payload and RLE

Fill and exterior-distance images expand to exactly `width * height` values.
Each value is an unpacked 4-bit integer in `0...15`.

An RLE control byte encodes `count = (control & 0x7f) + 1`:

- high bit set: the next byte is repeated `count` times;
- high bit clear: the next `count` bytes are literals.

Runs consume their complete declared byte range and may not expand beyond the
validated dimensions. The fill image carries antialiased glyph coverage. The
distance image carries fill as 15 and three exterior distance bands; firmware
chooses halo radius/opacity at runtime before drawing fill over the halo.

## Resource and trust rules

- At most 8,192 distinct glyph IDs and 24,576 glyph/size records.
- Glyph bitmaps are decoded into a 512-KiB bounded LRU, never all at once.
- The shared profile fingerprint in every FMB v3/v4 road-label section must match.
- Every shaped-run glyph ID/size pair must resolve.
- The signed map manifest SHA-256 authenticates the complete FMA file, but the
  device still performs all structural and cross-file validation before atomic
  activation.
