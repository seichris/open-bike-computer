"""Fixed metric processing regions and integer-aligned contour halos.

This is a versioned processing policy, not a coverage or jurisdiction map.
Requests crossing a region must be partitioned before sampling; choosing the
request centre would silently change the grid used by overlapping jobs.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

GRID_POLICY = "utm-polar-zero-origin-halo-v1"
HALO_PIXELS = 4


def region_resolution(policy, indexes, crs: str) -> int:
    """Choose one profile from the pinned catalog for the ENTIRE region.

    Include a one-degree neighbor band for the bounded processing halo. The
    profile cannot switch just because a small request omits a coarse tile.
    Catalog gaps still fail at sampling; no finer per-pixel fallback is implied.
    """
    epsg = int(crs.removeprefix("EPSG:"))
    if epsg == 3413:
        west, south, east, north = -180, 83, 180, 90
    elif epsg == 3031:
        west, south, east, north = -180, -90, 180, -79
    else:
        zone = epsg % 100
        west, east = -181 + (zone - 1) * 6, -179 + zone * 6
        south, north = (-1, 85) if epsg < 32700 else (-81, 1)
    claimed = set()
    resolution = 30
    for source in policy.sources:
        cells = indexes[source.id]
        if any(south <= lat < north and any(west <= lon + shift < east for shift in (-360, 0, 360))
               for lon, lat in cells - claimed):
            resolution = max(resolution, source.resolution_m)
        claimed.update(cells)
    return resolution


def processing_region(bounds: list[float]) -> str:
    if (len(bounds) != 4 or any(type(v) not in (int, float) or not math.isfinite(v) for v in bounds)):
        raise ValueError("processing bounds must be finite WGS84 coordinates")
    west, south, east, north = bounds
    if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
        raise ValueError("split wrapped or invalid processing bounds before sampling")
    if east - west > 6 or north - south > 6:
        raise ValueError("sample exceeds local projection extent")
    if south >= 84:
        return "EPSG:3413"
    if north <= -80:
        return "EPSG:3031"
    if south < -80 or north > 84 or south < 0 < north:
        raise ValueError("split selection at fixed processing region boundary")
    zone = min(60, math.floor((west + 180) / 6) + 1)
    if east > -180 + zone * 6:
        raise ValueError("split selection at fixed processing region boundary")
    return f"EPSG:{(32600 if south >= 0 else 32700) + zone}"


@dataclass(frozen=True)
class ContourGrid:
    crs: str
    resolution: int
    left: int
    bottom: int
    right: int
    top: int
    width: int
    height: int
    acquisition_bounds: tuple[float, float, float, float]

    def evidence(self) -> dict:
        return {"policy": GRID_POLICY, "region": self.crs, "originM": [0, 0],
                "haloPixels": HALO_PIXELS, "extentM": [self.left, self.bottom, self.right, self.top],
                "acquisitionBounds": list(self.acquisition_bounds)}


def contour_grid(bounds: list[float], resolution: int, maximum_pixels: int) -> ContourGrid:
    from rasterio.warp import transform_bounds

    if type(resolution) is not int or resolution not in (30, 90):
        raise ValueError("unsupported processing grid resolution")
    crs = processing_region(bounds)
    envelope = transform_bounds("EPSG:4326", crs, *bounds, densify_pts=41)
    if not all(math.isfinite(value) for value in envelope):
        raise ValueError("sample bounds cannot be represented by its processing region")
    left, bottom = (math.floor(v / resolution) * resolution - HALO_PIXELS * resolution for v in envelope[:2])
    right, top = (math.ceil(v / resolution) * resolution + HALO_PIXELS * resolution for v in envelope[2:])
    width, height = (right - left) // resolution, (top - bottom) // resolution
    if min(width, height) < 2 or width * height > maximum_pixels:
        raise ValueError("sample exceeds raster pixel bounds including halo")
    # The inverse envelope includes every geocell needed for reprojection, not
    # only cells touched by the user selection. A missing halo is not ocean.
    acquisition = transform_bounds(crs, "EPSG:4326", left, bottom, right, top, densify_pts=41)
    if (not all(math.isfinite(v) for v in acquisition) or acquisition[0] >= acquisition[2]
            or acquisition[2] - acquisition[0] > 12):
        raise ValueError("split cyclic or pole-enclosing halo before sampling")
    return ContourGrid(crs, resolution, left, bottom, right, top, width, height, acquisition)
