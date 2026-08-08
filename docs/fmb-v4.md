# FMB v4 Binary Map Block Format

FMB v4 adds bounded LoD1 building geometry to the complete FMB v3 street-label
layout. All integers are little-endian, signed integers use two's-complement,
and a block remains limited to 2 MiB with no undeclared or trailing bytes.

## Base geometry and label sections

The file begins with `FMB\x04`. Its polygon and polyline records are byte-for-
byte compatible with the typed FMB v2 base described in
[`fmb-v3.md`](fmb-v3.md). Section types 1, 2, and 3 are exactly the FMB v3
string, shaped-run, and road-label sections.

The extension directory immediately follows the base records:

```text
magic                       4 bytes = "EXT4"
sectionCount                u8 = 4
reserved                    3 bytes = 0
entries                     4 * 16 bytes
```

Directory entries retain the FMB v3 `type`, critical `flags`, reserved,
absolute offset, byte length, and IEEE CRC-32 fields. Entries are canonical,
contiguous, ordered by type, and cover every remaining byte. FMB v4 requires
all four critical sections:

| Type | Section |
| ---: | --- |
| 1 | UTF-8 string table |
| 2 | Shaped-run table |
| 3 | Road-label table |
| 4 | Building table |

## Type 4: buildings

The section starts with:

```text
buildingCount               u16, maximum 8,192
reserved                    u16 = 0
declaredPointCount          u32, maximum 131,072
```

Every building fragment has one fixed 18-byte record followed by its rings:

```text
typeId                      u8 = 100
flags                       u8; bit 0 marks building:part, bit 1 a flat base
heightProvenance            u8; 0...4
reserved                    u8 = 0
heightDecimeters            u16; greater than minimum height
minimumHeightDecimeters     u16
minimumX, minimumY          2 * i16
maximumX, maximumY          2 * i16
ringCount                   u16; 1...32
rings[ringCount]
```

A flat-base record preserves an outline (including courtyards) underneath a
complete set of building parts. Its stored height and provenance remain
auditable, but firmware projects its roof at ground level and never emits its
walls. Every wall-mask bit in a flat-base record must be zero. The part and
flat-base flags are mutually exclusive. All other flag bits are reserved and
must be zero.

The provenance values are:

| Value | Meaning |
| ---: | --- |
| 0 | Explicit valid OSM `height` |
| 1 | OSM levels-derived height |
| 2 | Inherited from an explicit or levels-derived parent outline |
| 3 | Median of eligible OSM heights in the configured local cell and halo |
| 4 | Checked-in OSM building-class default |

The resolver policy and current class-default values are documented in the
[`OSM_Extract` renderer-format guide](../tools/OSM_Extract/README.md#renderer-formats-and-osm-3d-buildings).
They are build policy rather than part of the binary wire format; the encoded
provenance keeps estimated heights distinguishable from explicit OSM data.

The first ring is the outer ring and every later ring is a hole:

```text
pointCount                  u16; 3...65,535
flags                       u8; 0 outer, 1 hole
reserved                    u8 = 0
points                      pointCount * (i16 x, i16 y)
wallMask                    ceil(pointCount / 8) bytes
```

Wall bit `i` describes the edge from point `i` to point `(i + 1) mod
pointCount`. A set bit permits a facade; a clear bit suppresses a clipping edge
created at a map-block boundary. Unused high bits in the final wall-mask byte
must be zero. Rings do not repeat their first point.

The record bounds must exactly equal the extrema of all encoded ring points.
The sum of all ring point counts must equal `declaredPointCount`. Heights use
physical decimetres; firmware applies one latitude-derived Web Mercator scale
per block before projecting the vertical displacement.

## Renderer target and compatibility

Renderer format 3 consists of FMB v4 blocks plus exactly one matching FMA1
street-label asset and building profile version 1. Bike Map Stream remains at
format v1. New firmware reads FMB v1 through v4; firmware without CAP2 feature
bit 12 must never receive renderer target 3.


## Runtime admission and presentation contract

FMB v4 defines geometry, not traversal priority. Firmware must consider records
from all loaded in-view blocks and choose a deterministic globally nearest set;
cache or block iteration order must not decide which buildings become 3D.
Fixed record, point, projected-pixel, courtyard-workspace, and PSRAM quotas are
applied after spatial ordering. Nearest eligible records may be extruded and
farther admitted records are drawn as dedicated flat FMB v4 footprints.
Records beyond those quotas are explicitly deferred; they are not assumed to
exist in the generic polygon stream. During a genuine allocation failure or
its scoped cooldown, firmware renders a smaller deterministic nearest set as
flat footprints without the normal candidate/sort workspace.

Building IO, discovery, sorting, courtyard capture, and surface rasterization
run only in a private render job. The worker writes a hidden raw RGB565 surface
and never calls LVGL. Position-only requests are coalesced while semantic
invalidations cancel at cooperative checkpoints; this keeps the last complete
frame moving without making an otherwise healthy frame globally 2D. Allocation,
corruption, and invariant failures are the only reasons to enter the documented
flat fallback/cooldown path.
