"""Bounded DEM-derived experimental terrain grids, shared by phone and device.

FME1 is a 33x33 north/east-positive Web Mercator grid at 128 m spacing.
Each node is signed metre elevation, geographic hillshade, and slope degrees.
No-data is explicit. It is never interpolated from contour lines.
"""
from __future__ import annotations
import base64
import math
import struct
import zlib

SIDE = 33
STEP = 128
BLOCK = 4096
NODATA = -32768
SIZE = 16 + SIDE * SIDE * 4
MAX_BLOCKS = 256
ALGORITHM = "dem-grid-128m-horn-nw45-v1"


def validate_grid(data: bytes) -> tuple[int, int]:
    if len(data) != SIZE or data[:4] != b"FME1":
        raise ValueError("invalid terrain grid size/header")
    bx, by, crc = struct.unpack_from("<iiI", data, 4)
    if not (-4892 <= bx <= 4891 and -4892 <= by <= 4891):
        raise ValueError("terrain grid outside Mercator world")
    if zlib.crc32(data[16:]) != crc:
        raise ValueError("terrain grid CRC mismatch")
    for h, shade, slope in struct.iter_unpack("<hBB", data[16:]):
        if h == NODATA:
            if shade or slope:
                raise ValueError("no-data terrain carries relief")
        elif not -12000 <= h <= 10000 or slope > 90:
            raise ValueError("invalid terrain node")
    return bx, by


def encode_grid(bx: int, by: int, nodes) -> bytes:
    payload = b"".join(struct.pack("<hBB", *node) for node in nodes)
    data = b"FME1" + struct.pack("<iiI", bx, by, zlib.crc32(payload)) + payload
    validate_grid(data)
    return data


def grids_from_mosaic(mosaic, grid, bounds, cancel=lambda: None, *, selection=None) -> list[str]:
    """Sample globally aligned nodes and a one-node derivative halo per block.

    The mosaic must include its processing halo. Unsupported samples remain
    absent; no extrapolation across no-data or beyond source coverage occurs.
    Memory added per processing block is bounded independently of map area.
    """
    import numpy as np
    from rasterio.warp import transform
    xs, ys = transform("EPSG:4326", "EPSG:3857", [bounds[0], bounds[2]], [bounds[1], bounds[3]])
    xkeys = range(math.floor(xs[0] / BLOCK), math.floor(xs[1] / BLOCK) + 1)
    ykeys = range(math.floor(ys[0] / BLOCK), math.floor(ys[1] / BLOCK) + 1)
    if selection is None and len(xkeys) * len(ykeys) > MAX_BLOCKS:
        raise ValueError("terrain exceeds 256 block budget")
    height, width = mosaic.shape
    outputs = []
    region = prepare_selection(selection) if selection is not None else None
    for bx, by in selected_block_keys(xkeys, ykeys, region, cancel):
        cancel()
        wx, wy = np.meshgrid(bx * BLOCK + np.arange(-1, SIDE + 1) * STEP,
                             by * BLOCK + np.arange(-1, SIDE + 1) * STEP)
        px, py = transform("EPSG:3857", grid.crs, wx.ravel().tolist(), wy.ravel().tolist())
        # contour_grid sample positions are pixel centres (see extract_contours).
        cols = (np.asarray(px) - grid.left) / grid.resolution - 0.5
        rows = (grid.top - np.asarray(py)) / grid.resolution - 0.5
        c0, r0 = np.floor(cols).astype(int), np.floor(rows).astype(int)
        valid = (c0 >= 0) & (r0 >= 0) & (c0 + 1 < width) & (r0 + 1 < height)
        sampled = np.full(cols.shape, np.nan)
        indices = np.flatnonzero(valid)
        c, r = c0[indices], r0[indices]
        dx, dy = cols[indices] - c, rows[indices] - r
        values = np.zeros(len(indices)); present = np.ones(len(indices), dtype=bool)
        for rr, cc, weight in ((r, c, (1-dx)*(1-dy)), (r, c+1, dx*(1-dy)),
                               (r+1, c, (1-dx)*dy), (r+1, c+1, dx*dy)):
            v = mosaic[rr, cc]
            present &= (weight == 0) | np.isfinite(v)
            values += np.where(np.isfinite(v), v, 0) * weight
        sampled[indices[present]] = values[present]
        sampled = sampled.reshape((SIDE + 2, SIDE + 2))
        nodes = []
        for y in range(SIDE):
            cancel()
            latitude = math.atan(math.sinh((by * BLOCK + y * STEP) / 6378137))
            spacing = STEP * math.cos(latitude)
            for x in range(SIDE):
                window = sampled[y:y+3, x:x+3]
                if not np.isfinite(window).all():
                    nodes.append((NODATA, 0, 0)); continue
                # Row order is south to north; illumination comes from NW, 45°.
                gx = ((window[0,2]+2*window[1,2]+window[2,2]) -
                      (window[0,0]+2*window[1,0]+window[2,0])) / (8*spacing)
                gy = ((window[2,0]+2*window[2,1]+window[2,2]) -
                      (window[0,0]+2*window[0,1]+window[0,2])) / (8*spacing)
                shade = max(0, (gx * 0.5 - gy * 0.5 + math.sqrt(0.5)) / math.sqrt(1+gx*gx+gy*gy))
                nodes.append((round(float(window[1,1])), round(shade*255), round(math.degrees(math.atan(math.hypot(gx,gy))))))
        if any(node[0] != NODATA for node in nodes):
            data = encode_grid(bx, by, nodes)
            if region is not None:
                data = clip_grid(data, region, cancel)
            if any(h != NODATA for h, _, _ in struct.iter_unpack("<hBB", data[16:])):
                outputs.append(base64.b64encode(data).decode("ascii"))
                if len(outputs) > MAX_BLOCKS:
                    raise ValueError("terrain exceeds 256 block budget")
    return outputs


def prepare_selection(selection):
    from shapely.geometry import shape
    from shapely.prepared import prep
    return prep(shape(selection)) if isinstance(selection, dict) else selection


def selected_block_keys(xkeys, ykeys, region, cancel):
    """Skip empty rows and gaps between polygon components before DEM sampling."""
    from shapely.geometry import box
    for by in ykeys:
        cancel()
        if region is None:
            intervals = [(xkeys.start, xkeys.stop - 1)]
        else:
            strip = region.context.intersection(box(xkeys.start * BLOCK, by * BLOCK,
                                                     xkeys.stop * BLOCK, (by + 1) * BLOCK))
            def parts(geometry):
                if geometry.is_empty:
                    return
                if hasattr(geometry, "geoms"):
                    for child in geometry.geoms:
                        yield from parts(child)
                else:
                    yield geometry
            intervals = sorted((max(xkeys.start, math.floor(part.bounds[0] / BLOCK)),
                                min(xkeys.stop - 1, math.floor(part.bounds[2] / BLOCK)))
                               for part in parts(strip))
        previous = xkeys.start - 1
        for start, end in intervals:
            for bx in range(max(start, previous + 1), end + 1):
                cancel()
                if region is None or region.intersects(box(bx * BLOCK, by * BLOCK,
                                                            (bx + 1) * BLOCK, (by + 1) * BLOCK)):
                    yield bx, by
            previous = max(previous, end)


def clip_grid(data: bytes, selection, cancel=lambda: None) -> bytes:
    from shapely.geometry import Point
    bx, by = validate_grid(data)
    region = prepare_selection(selection)
    nodes = []
    for i, node in enumerate(struct.iter_unpack("<hBB", data[16:])):
        if i % SIDE == 0:
            cancel()
        point = Point(bx*BLOCK+(i % SIDE)*STEP, by*BLOCK+(i // SIDE)*STEP)
        nodes.append(node if region.covers(point) else (NODATA, 0, 0))
    return encode_grid(bx, by, nodes)


def sampling_bounds(bounds: list[float]) -> list[float]:
    from rasterio.warp import transform_bounds
    west, south, east, north = transform_bounds("EPSG:4326", "EPSG:3857", *bounds)
    result = list(transform_bounds("EPSG:3857", "EPSG:4326",
        math.floor(west / BLOCK)*BLOCK-256, math.floor(south / BLOCK)*BLOCK-256,
        (math.floor(east / BLOCK)+1)*BLOCK+256, (math.floor(north / BLOCK)+1)*BLOCK+256))
    if not (-180 <= result[0] < result[2] <= 180 and -85.05112878 <= result[1] < result[3] <= 85.05112878):
        raise ValueError("terrain halo exceeds supported Mercator domain")
    return result
