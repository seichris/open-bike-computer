from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass
from typing import Any

from .models import Bounds, GeometryMode, MapJob


MAP_BLOCK_SIZE_METERS = 1 << 12
MAP_FOLDER_BLOCKS = 1 << 4
MAP_REUSE_SCHEMA_VERSION = 1
EARTH_RADIUS_METERS = 6_378_137
_SHA256_RE = re.compile(r"[0-9a-f]{64}")
_IMAGE_DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")
_BLOCK_PATH_RE = re.compile(
    r"VECTMAP/[^/]+/(?P<folder>[+-]\d{3,}[+-]\d{3,})/"
    r"(?P<block_x>\d{1,2})_(?P<block_y>\d{1,2})\.(?P<extension>fmb|fmp)"
)


@dataclass(frozen=True)
class MapReuseKeys:
    exact: str
    compatibility: str


@dataclass(frozen=True, order=True)
class MapBlock:
    x: int
    y: int

    @property
    def folder_x(self) -> int:
        return self.x >> 4

    @property
    def folder_y(self) -> int:
        return self.y >> 4

    @property
    def local_x(self) -> int:
        return self.x & (MAP_FOLDER_BLOCKS - 1)

    @property
    def local_y(self) -> int:
        return self.y & (MAP_FOLDER_BLOCKS - 1)

    @property
    def folder_name(self) -> str:
        return f"{self.folder_x:+04d}{self.folder_y:+04d}"

    @property
    def filename_stem(self) -> str:
        return f"{self.local_x}_{self.local_y}"


class SubsetReuseUnavailable(RuntimeError):
    """The candidate cannot be safely reused; the caller should build normally."""


def reuse_keys(
    job: MapJob,
    *,
    producer_build_sha256: str | None,
    producer_image_digest: str | None,
    source_snapshot_sha256: str | None = None,
) -> MapReuseKeys | None:
    """Return fail-closed cache identities for an immutable worker build."""
    if not _SHA256_RE.fullmatch(producer_build_sha256 or ""):
        return None
    if not _IMAGE_DIGEST_RE.fullmatch(producer_image_digest or ""):
        return None
    declared_checksum = job.source_region.checksum
    if declared_checksum is not None and not _SHA256_RE.fullmatch(declared_checksum):
        return None
    if (
        declared_checksum is not None
        and source_snapshot_sha256 is not None
        and source_snapshot_sha256 != declared_checksum
    ):
        return None
    snapshot_sha256 = declared_checksum or source_snapshot_sha256
    if not _SHA256_RE.fullmatch(snapshot_sha256 or ""):
        return None

    compatibility_document: dict[str, Any] = {
        "schemaVersion": MAP_REUSE_SCHEMA_VERSION,
        "producer": {
            "buildSha256": producer_build_sha256,
            "imageDigest": producer_image_digest,
        },
        "renderer": {
            "name": "esp32-fmb",
            "formatVersion": 1,
            "blockSizeMeters": MAP_BLOCK_SIZE_METERS,
        },
        "source": {
            "provider": job.source_region.provider,
            "id": job.source_region.id,
            "url": job.source_region.url,
            "publishedAt": job.source_region.published_at,
            "checksum": job.source_region.checksum,
            "snapshotSha256": snapshot_sha256,
        },
        "target": job.request.get("target") or {},
    }
    compatibility = _document_sha256(compatibility_document)
    exact_document = {
        "compatibilityKey": compatibility,
        "packDisplayName": job.request.get("displayName"),
        "geometry": {
            "mode": job.geometry.mode.value,
            "bounds": job.geometry.bounds.to_list(),
            "geometry": job.geometry.geometry,
            "routePointCount": job.geometry.route_point_count,
            "corridorWidthM": job.geometry.corridor_width_m,
        },
    }
    return MapReuseKeys(
        exact=_document_sha256(exact_document),
        compatibility=compatibility,
    )


def aligned_processing_bounds(job: MapJob) -> Bounds:
    """Expand bounding-box builds to complete fixed Web Mercator blocks."""
    if job.geometry.mode != GeometryMode.CUSTOM_BBOX:
        return job.geometry.bounds
    min_x, min_y, max_x, max_y = aligned_projected_extent(job.geometry.bounds)
    return Bounds(
        _x_to_lon(min_x),
        _y_to_lat(min_y),
        _x_to_lon(max_x),
        _y_to_lat(max_y),
    )


def aligned_projected_extent(bounds: Bounds) -> tuple[int, int, int, int]:
    min_x = math.floor(_lon_to_x(bounds.min_lon) / MAP_BLOCK_SIZE_METERS) * MAP_BLOCK_SIZE_METERS
    min_y = math.floor(_lat_to_y(bounds.min_lat) / MAP_BLOCK_SIZE_METERS) * MAP_BLOCK_SIZE_METERS
    max_x = math.ceil(_lon_to_x(bounds.max_lon) / MAP_BLOCK_SIZE_METERS) * MAP_BLOCK_SIZE_METERS
    max_y = math.ceil(_lat_to_y(bounds.max_lat) / MAP_BLOCK_SIZE_METERS) * MAP_BLOCK_SIZE_METERS
    if max_x <= min_x or max_y <= min_y:
        raise ValueError("map bounds do not cover a complete map block")
    return min_x, min_y, max_x, max_y


def required_blocks(bounds: Bounds) -> set[MapBlock]:
    min_x, min_y, max_x, max_y = aligned_projected_extent(bounds)
    return {
        MapBlock(x, y)
        for x in range(min_x // MAP_BLOCK_SIZE_METERS, max_x // MAP_BLOCK_SIZE_METERS)
        for y in range(min_y // MAP_BLOCK_SIZE_METERS, max_y // MAP_BLOCK_SIZE_METERS)
    }


def parent_contains_child_blocks(parent: MapJob, child: MapJob) -> bool:
    if (
        parent.geometry.mode != GeometryMode.CUSTOM_BBOX
        or child.geometry.mode != GeometryMode.CUSTOM_BBOX
    ):
        return False
    parent_min_x, parent_min_y, parent_max_x, parent_max_y = aligned_projected_extent(
        parent.geometry.bounds
    )
    child_min_x, child_min_y, child_max_x, child_max_y = aligned_projected_extent(
        child.geometry.bounds
    )
    return (
        parent_min_x <= child_min_x
        and parent_min_y <= child_min_y
        and parent_max_x >= child_max_x
        and parent_max_y >= child_max_y
        and (
            parent_min_x < child_min_x
            or parent_min_y < child_min_y
            or parent_max_x > child_max_x
            or parent_max_y > child_max_y
        )
    )


def block_from_pack_path(path: str) -> MapBlock | None:
    match = _BLOCK_PATH_RE.fullmatch(path)
    if match is None:
        return None
    folder = match.group("folder")
    # Folder names concatenate two signed, at-least-four-character integers.
    split = next(
        (index for index in range(1, len(folder)) if folder[index] in "+-"),
        None,
    )
    if split is None:
        return None
    try:
        folder_x = int(folder[:split])
        folder_y = int(folder[split:])
        local_x = int(match.group("block_x"))
        local_y = int(match.group("block_y"))
    except ValueError:
        return None
    if not 0 <= local_x < MAP_FOLDER_BLOCKS or not 0 <= local_y < MAP_FOLDER_BLOCKS:
        return None
    return MapBlock(
        (folder_x << 4) + local_x,
        (folder_y << 4) + local_y,
    )


def child_pack_path(map_id: str, block: MapBlock, extension: str) -> str:
    if extension not in {"fmb", "fmp"}:
        raise ValueError("unsupported map block extension")
    return (
        f"VECTMAP/{map_id}/{block.folder_name}/"
        f"{block.filename_stem}.{extension}"
    )


def _document_sha256(document: dict[str, Any]) -> str:
    encoded = json.dumps(
        document,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _lon_to_x(lon: float) -> int:
    return round(math.radians(lon) * EARTH_RADIUS_METERS)


def _lat_to_y(lat: float) -> int:
    return round(
        math.log(math.tan(math.radians(lat) / 2 + math.pi / 4))
        * EARTH_RADIUS_METERS
    )


def _x_to_lon(x: int) -> float:
    return math.degrees(x / EARTH_RADIUS_METERS)


def _y_to_lat(y: int) -> float:
    return math.degrees(2 * math.atan(math.exp(y / EARTH_RADIUS_METERS)) - math.pi / 2)
