"""Deterministic, bounded offline iPhone contour tiles (not Apple map data).

Coordinates use XYZ, north-origin Web Mercator. SQLite's application/user IDs,
exact schema, canonical metadata, per-tile hashes and PNG dimensions are all
validated before a companion can become a published artifact.
"""
from __future__ import annotations

import hashlib
import io
import json
import math
import os
import re
import sqlite3
import tempfile
from pathlib import Path
from typing import Callable

from PIL import Image, ImageDraw

from .topography_cache import _sync_directory
from .topography_geometry import CompiledTopography, MAX_WORLD_METRES
from .topography_pipeline import canonical_bytes

APPLICATION_ID = 0x42544F50  # BTOP
MAX_BYTES = 256 * 1024 * 1024
MAX_TILES = 16_384  # Includes both display scales.
MAX_TILE_BYTES = 1024 * 1024
MIN_ZOOM, MAX_ZOOM = 9, 16
STYLE_ID = "contours-transparent-20-50-v1"
SCHEMA = (
    "CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL)",
    "CREATE TABLE tiles (z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, scale INTEGER NOT NULL, png BLOB NOT NULL, sha256 TEXT NOT NULL, PRIMARY KEY (z, x, y, scale)) WITHOUT ROWID",
)


def _digest(value: str) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def _validate_metadata(metadata: dict) -> None:
    if not isinstance(metadata, dict) or set(metadata) != {
        "schemaVersion", "profileVersion", "styleId", "tileScheme", "tileSize", "scales", "minimumZoom", "maximumZoom",
        "mapId", "intermediateSha256", "sourcePolicySha256", "attributionSha256", "boundsE7", "tileCount",
    }:
        raise ValueError("companion metadata fields differ")
    constants = {"schemaVersion": 1, "profileVersion": 1, "styleId": STYLE_ID, "tileScheme": "xyz",
                 "tileSize": 256, "scales": [1, 2], "minimumZoom": MIN_ZOOM, "maximumZoom": MAX_ZOOM}
    if any(type(metadata[key]) is not type(value) or metadata[key] != value for key, value in constants.items()):
        raise ValueError("unsupported companion profile")
    if not isinstance(metadata["mapId"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", metadata["mapId"]):
        raise ValueError("invalid companion map identity")
    if any(not _digest(metadata[key]) for key in ("intermediateSha256", "sourcePolicySha256", "attributionSha256")):
        raise ValueError("invalid companion content binding")
    bounds = metadata["boundsE7"]
    if (not isinstance(bounds, list) or len(bounds) != 4 or any(type(v) is not int for v in bounds)
            or not (-1800000000 <= bounds[0] < bounds[2] <= 1800000000
                    and -850511288 <= bounds[1] < bounds[3] <= 850511288)):
        raise ValueError("invalid companion bounds")
    if type(metadata["tileCount"]) is not int or not 0 <= metadata["tileCount"] <= MAX_TILES:
        raise ValueError("companion tile count exceeds bounds")


def _png_valid(data: bytes, scale: int) -> None:
    if not 1 <= len(data) <= MAX_TILE_BYTES or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("invalid companion PNG length/header")
    with Image.open(io.BytesIO(data)) as image:
        if image.format != "PNG" or image.mode != "RGBA" or image.size != (256 * scale, 256 * scale):
            raise ValueError("companion PNG must be a transparent display-scale tile")
        image.verify()
    with Image.open(io.BytesIO(data)) as image:
        image.load()
        if image.getchannel("A").getbbox() is None:
            raise ValueError("empty tiles must be omitted")


def validate_companion(path: Path, *, expected_map_id: str | None = None,
                       expected_intermediate: str | None = None,
                       cancel: Callable[[], None] = lambda: None) -> dict:
    if path.is_symlink() or not path.is_file() or not 512 <= path.stat().st_size <= MAX_BYTES:
        raise ValueError("invalid companion file")
    # URI escaping belongs to Path.as_uri(), not string concatenation with an
    # unescaped file name containing '?' or '#'. Immutable avoids journal I/O.
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
    try:
        connection.execute("PRAGMA trusted_schema=OFF")
        connection.execute("PRAGMA query_only=ON")
        if hasattr(connection, "setlimit"):
            connection.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, MAX_TILE_BYTES + 65536)
        connection.set_progress_handler(lambda: (cancel(), 0)[1], 1000)
        if (connection.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID
                or connection.execute("PRAGMA user_version").fetchone()[0] != 1
                or connection.execute("PRAGMA page_size").fetchone()[0] != 4096):
            raise ValueError("unsupported companion SQLite identity")
        if connection.execute("SELECT count(*), coalesce(max(length(sql)), 0), coalesce(max(length(name)), 0) FROM sqlite_schema").fetchone() != (2, max(map(len, SCHEMA)), 8):
            raise ValueError("unexpected companion SQLite schema bounds")
        actual = connection.execute("SELECT type, name, sql FROM sqlite_schema ORDER BY name").fetchall()
        if actual != [("table", "metadata", SCHEMA[0]), ("table", "tiles", SCHEMA[1])]:
            raise ValueError("unexpected companion SQLite schema")
        if connection.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise ValueError("corrupt companion database")
        if connection.execute("SELECT count(*), coalesce(max(length(json)), 0) FROM metadata").fetchone()[0] != 1:
            raise ValueError("invalid companion metadata count")
        if connection.execute("SELECT length(json) FROM metadata").fetchone()[0] > 16384:
            raise ValueError("companion metadata exceeds bounds")
        rows = connection.execute("SELECT id, json FROM metadata").fetchall()
        if len(rows) != 1 or rows[0][0] != 1 or len(rows[0][1]) > 16384:
            raise ValueError("invalid companion metadata row")
        metadata = json.loads(rows[0][1])
        _validate_metadata(metadata)
        if canonical_bytes(metadata).decode() != rows[0][1]:
            raise ValueError("noncanonical companion metadata")
        if expected_map_id is not None and metadata["mapId"] != expected_map_id:
            raise ValueError("companion belongs to a different map")
        if expected_intermediate is not None and metadata["intermediateSha256"] != expected_intermediate:
            raise ValueError("companion belongs to different contour content")
        count = 0
        keys = set()
        count_bound, byte_bound = connection.execute("SELECT count(*), coalesce(max(length(png)), 0) FROM tiles").fetchone()
        if count_bound > MAX_TILES or byte_bound > MAX_TILE_BYTES:
            raise ValueError("companion tile storage exceeds bounds")
        for z, x, y, scale, png, sha in connection.execute("SELECT z, x, y, scale, png, sha256 FROM tiles ORDER BY z, x, y, scale"):
            cancel()
            count += 1
            if (count > MAX_TILES or any(type(v) is not int for v in (z, x, y, scale))
                    or not MIN_ZOOM <= z <= MAX_ZOOM or not (0 <= x < 2**z and 0 <= y < 2**z)
                    or scale not in (1, 2) or not isinstance(png, bytes)
                    or not _digest(sha) or hashlib.sha256(png).hexdigest() != sha):
                raise ValueError("invalid companion tile record")
            _png_valid(png, scale)
            keys.add((z, x, y, scale))
        if count != metadata["tileCount"] or any((z, x, y, 3 - scale) not in keys for z, x, y, scale in keys):
            raise ValueError("companion tile count or display-scale pair differs")
        return metadata
    finally:
        connection.close()


def write_companion(path: Path, compiled: CompiledTopography, *, map_id: str,
                    source_policy_sha256: str, attribution_sha256: str, bounds_e7: list[int],
                    cancel: Callable[[], None] = lambda: None) -> dict:
    if path.exists() or path.is_symlink():
        raise FileExistsError(path)
    # Index bounded line references by tile; never hold all decoded tile images.
    tiles: dict[tuple[int, int, int], list[tuple[bool, tuple]]] = {}
    references = 0
    for (bx, by), section in sorted(compiled.sections.items()):
        for contour in section.contours:
            cancel()
            world = [(bx * 4096 + x, by * 4096 + y) for x, y in contour.points]
            for z in range(MIN_ZOOM, MAX_ZOOM + 1):
                span = 2 * MAX_WORLD_METRES / 2**z
                points = tuple(((x + MAX_WORLD_METRES) / span, (MAX_WORLD_METRES - y) / span) for x, y in world)
                # Include stroke bleed; device block seams must not become PNG
                # tile seams. A tile is still stored only if alpha is nonempty.
                bleed = 2 / 256
                left = max(0, math.floor(min(p[0] for p in points) - bleed))
                right = min(2**z - 1, math.floor(max(p[0] for p in points) + bleed))
                top = max(0, math.floor(min(p[1] for p in points) - bleed))
                bottom = min(2**z - 1, math.floor(max(p[1] for p in points) + bleed))
                for x in range(left, right + 1):
                    for y in range(top, bottom + 1):
                        references += 1
                        tiles.setdefault((z, x, y), []).append((bool(contour.flags & 1), points))
                        if len(tiles) * 2 > MAX_TILES or references > 250_000:
                            raise ValueError("companion exceeds tile/reference admission budget")
    metadata = {"schemaVersion": 1, "profileVersion": 1, "styleId": STYLE_ID, "tileScheme": "xyz", "tileSize": 256,
                "scales": [1, 2], "minimumZoom": MIN_ZOOM, "maximumZoom": MAX_ZOOM, "mapId": map_id,
                "intermediateSha256": compiled.intermediate_sha256, "sourcePolicySha256": source_policy_sha256,
                "attributionSha256": attribution_sha256, "boundsE7": bounds_e7, "tileCount": 0}
    _validate_metadata(metadata)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="topography-ios-", dir=path.parent) as tmp:
        staged = Path(tmp) / "companion.btopo"
        connection = sqlite3.connect(staged)
        try:
            connection.execute("PRAGMA page_size=4096")
            connection.execute("PRAGMA journal_mode=DELETE")
            connection.execute("PRAGMA synchronous=FULL")
            connection.execute(f"PRAGMA application_id={APPLICATION_ID}")
            connection.execute("PRAGMA user_version=1")
            connection.execute(f"PRAGMA max_page_count={MAX_BYTES // 4096}")
            for sql in SCHEMA:
                connection.execute(sql)
            for (z, x, y), contours in sorted(tiles.items()):
                cancel()
                rendered = []
                for scale in (1, 2):
                    size = 256 * scale
                    image = Image.new("RGBA", (size, size))
                    draw = ImageDraw.Draw(image)
                    for is_index, points in sorted(contours):
                        draw.line([(round((px - x) * size), round((py - y) * size)) for px, py in points],
                                  fill=(139, 120, 80, 220) if is_index else (168, 148, 109, 170),
                                  width=(2 if is_index else 1) * scale)
                    # Pair publication is atomic: keep a transparent scale
                    # only if its counterpart also has visible content.
                    if image.getchannel("A").getbbox() is None:
                        break
                    buffer = io.BytesIO()
                    image.save(buffer, format="PNG", optimize=False, compress_level=9)
                    png = buffer.getvalue()
                    if len(png) > MAX_TILE_BYTES:
                        raise ValueError("companion tile exceeds encoded byte budget")
                    rendered.append((z, x, y, scale, png, hashlib.sha256(png).hexdigest()))
                if len(rendered) == 2:
                    connection.executemany("INSERT INTO tiles VALUES (?, ?, ?, ?, ?, ?)", rendered)
                    metadata["tileCount"] += 2
            connection.execute("INSERT INTO metadata VALUES (1, ?)", (canonical_bytes(metadata).decode(),))
            connection.commit()
            connection.execute("VACUUM")
        finally:
            connection.close()
        validate_companion(staged, expected_map_id=map_id, expected_intermediate=compiled.intermediate_sha256, cancel=cancel)
        cancel()
        with staged.open("rb") as file:
            os.fsync(file.fileno())
        os.link(staged, path)
        _sync_directory(path.parent)
    return metadata
