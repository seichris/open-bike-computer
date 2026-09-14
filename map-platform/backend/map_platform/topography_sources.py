"""Pinned elevation coverage and deterministic selection; no user-job enablement.

Index coverage describes published geocells, not a promise of valid elevations
at every pixel. Raster no-data is checked by the terrain stage independently.
"""
from __future__ import annotations

import hashlib
import math
import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any, Mapping
from urllib.parse import urlsplit

from .strict_json import loads_strict_json

MAX_INDEX_BYTES = 4 * 1024 * 1024
MAX_PLAN_CELLS = 256
SHA256 = re.compile(r"[0-9a-f]{64}")
TILE_NAME = re.compile(r"Copernicus_DSM_COG_(10|30)_([NS])(\d{2})_00_([EW])(\d{3})_00_DEM")
SOURCE_FIELDS = frozenset({
    "id", "priority", "adapter", "datasetRelease", "resolutionM", "surfaceModel",
    "horizontalCrs", "verticalDatum", "verticalUnits", "origin",
    "tileIndexSha256", "tileIndexBytes", "tileCount", "termsUrl", "attributionUrl",
    "accessReviewedAt", "productionApproved",
})


def _integer(value: object, minimum: int, maximum: int, field: str) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"invalid topography {field}")
    return value


def _https(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 2048:
        raise ValueError(f"invalid topography {field}")
    try:
        url = urlsplit(value)
        valid = (url.scheme == "https" and url.hostname and not url.username
                 and not url.password and url.port is None and not url.query
                 and not url.fragment and not any(ord(c) <= 32 for c in value))
    except ValueError:
        valid = False
    if not valid:
        raise ValueError(f"invalid topography {field}")
    return value


@dataclass(frozen=True)
class ElevationSource:
    id: str
    priority: int
    dataset_release: str
    resolution_m: int
    origin: str
    index_sha256: str
    index_bytes: int
    tile_count: int
    terms_url: str
    attribution_url: str
    access_reviewed_at: str

    @property
    def index_url(self) -> str:
        return self.origin + "/tileList.txt"

    def tile_name(self, longitude: int, latitude: int) -> str:
        _integer(longitude, -180, 179, "tile longitude")
        _integer(latitude, -90, 89, "tile latitude")
        arcseconds = "10" if self.resolution_m == 30 else "30"
        return (f"Copernicus_DSM_COG_{arcseconds}_"
                f"{'S' if latitude < 0 else 'N'}{abs(latitude):02d}_00_"
                f"{'W' if longitude < 0 else 'E'}{abs(longitude):03d}_00_DEM")

    def tile_url(self, longitude: int, latitude: int) -> str:
        name = self.tile_name(longitude, latitude)
        return f"{self.origin}/{name}/{name}.tif"

    def validate_url(self, value: str) -> str:
        _https(value, "download URL")
        if value == self.index_url:
            return value
        prefix = self.origin + "/"
        if value.startswith(prefix):
            parts = value[len(prefix):].split("/")
            if len(parts) == 2 and parts[1] == parts[0] + ".tif":
                self.parse_tile_name(parts[0])
                return value
        raise ValueError("elevation URL is outside the approved source")

    def parse_tile_name(self, name: str) -> tuple[int, int]:
        match = TILE_NAME.fullmatch(name)
        if match is None:
            raise ValueError("invalid Copernicus tile name")
        latitude = int(match[3]) * (-1 if match[2] == "S" else 1)
        longitude = int(match[5]) * (-1 if match[4] == "W" else 1)
        if self.tile_name(longitude, latitude) != name:
            raise ValueError("noncanonical Copernicus tile name")
        return longitude, latitude


@dataclass(frozen=True)
class TopographySourcePolicy:
    sources: tuple[ElevationSource, ...]
    sha256: str
    version: int

    @classmethod
    def load(cls, path: Path) -> TopographySourcePolicy:
        if path.stat().st_size > 64 * 1024:
            raise ValueError("topography policy exceeds size bound")
        raw = path.read_bytes()
        data = loads_strict_json(raw, description="topography source policy")
        if not isinstance(data, dict) or set(data) != {"schemaVersion", "policyVersion", "access", "sources"}:
            raise ValueError("invalid topography policy fields")
        _integer(data["schemaVersion"], 1, 1, "schema version")
        version = _integer(data["policyVersion"], 1, 2**31 - 1, "policy version")
        if data["access"] != "free":
            raise ValueError("topography access must be free")
        values = data["sources"]
        if not isinstance(values, list) or not 1 <= len(values) <= 32:
            raise ValueError("invalid topography sources")
        sources = []
        for value in values:
            if not isinstance(value, dict) or set(value) != SOURCE_FIELDS:
                raise ValueError("invalid topography source fields")
            if not isinstance(value["id"], str) or re.fullmatch(r"[a-z][a-z0-9-]{2,63}", value["id"]) is None:
                raise ValueError("invalid topography source id")
            if (value["adapter"] != "copernicus-cog-v1" or value["datasetRelease"] != "2021"
                    or value["surfaceModel"] != "dsm" or value["horizontalCrs"] != "EPSG:4326"
                    or value["verticalDatum"] != "EPSG:3855" or value["verticalUnits"] != "m"):
                raise ValueError("unsupported topography source contract")
            # This acquisition slice must not masquerade as production approval.
            if value["productionApproved"] is not False:
                raise ValueError("topography production approval is not implemented")
            resolution = _integer(value["resolutionM"], 30, 90, "resolution")
            if resolution not in (30, 90) or value["origin"] != f"https://copernicus-dem-{resolution}m.s3.amazonaws.com":
                raise ValueError("unsupported topography origin or resolution")
            digest = value["tileIndexSha256"]
            if not isinstance(digest, str) or SHA256.fullmatch(digest) is None:
                raise ValueError("invalid topography index checksum")
            reviewed = value["accessReviewedAt"]
            if not isinstance(reviewed, str) or date.fromisoformat(reviewed).isoformat() != reviewed:
                raise ValueError("invalid topography review date")
            sources.append(ElevationSource(
                value["id"], _integer(value["priority"], 1, 10000, "priority"),
                value["datasetRelease"], resolution, value["origin"], digest,
                _integer(value["tileIndexBytes"], 1, MAX_INDEX_BYTES, "index bytes"),
                _integer(value["tileCount"], 1, 64800, "tile count"),
                _https(value["termsUrl"], "terms URL"),
                _https(value["attributionUrl"], "attribution URL"), reviewed,
            ))
        if len({s.id for s in sources}) != len(sources) or len({s.priority for s in sources}) != len(sources):
            raise ValueError("duplicate topography source id or priority")
        if sources != sorted(sources, key=lambda s: -s.priority):
            raise ValueError("topography sources must be ordered by descending priority")
        return cls(tuple(sources), hashlib.sha256(raw).hexdigest(), version)

    def public_summary(self) -> dict[str, Any]:
        return {"access": "free", "generationEnabled": False, "policyVersion": self.version,
                "sourcePolicySha256": self.sha256, "acquisitionSourceCount": len(self.sources)}


def load_topography_source_policy(repo_root: Path) -> TopographySourcePolicy:
    return TopographySourcePolicy.load(repo_root / "map-platform/config/topography-source-policy-v1.json")


def parse_tile_index(source: ElevationSource, raw: bytes) -> frozenset[tuple[int, int]]:
    if len(raw) != source.index_bytes or hashlib.sha256(raw).hexdigest() != source.index_sha256:
        raise ValueError("elevation tile index does not match pinned bytes/checksum")
    try:
        names = raw.decode("ascii").splitlines()
    except UnicodeDecodeError as exc:
        raise ValueError("elevation tile index is not ASCII") from exc
    if len(names) != source.tile_count:
        raise ValueError("elevation tile index count differs from policy")
    cells = frozenset(source.parse_tile_name(name) for name in names)
    if len(cells) != len(names):
        raise ValueError("duplicate elevation tile")
    return cells


def geocells(bounds: list[float] | tuple[float, ...], *, maximum: int = MAX_PLAN_CELLS) -> tuple[tuple[int, int], ...]:
    _integer(maximum, 1, MAX_PLAN_CELLS, "maximum geocells")
    if len(bounds) != 4 or any(type(v) not in (int, float) or not math.isfinite(v) for v in bounds):
        raise ValueError("bounds must be four finite WGS84 numbers")
    west, south, east, north = bounds
    if not (-180 <= west <= 180 and -180 <= east <= 180 and -90 <= south < north <= 90) or west == east:
        raise ValueError("invalid WGS84 bounds")
    spans = [(west, east)] if west < east else [(west, 180), (-180, east)]
    width = sum(math.ceil(right) - math.floor(left) for left, right in spans if left < right)
    height = math.ceil(north) - math.floor(south)
    if width * height > maximum:
        raise ValueError("elevation request exceeds geocell limit")
    cells = {(lon, lat) for left, right in spans if left < right
             for lon in range(math.floor(left), math.ceil(right))
             for lat in range(math.floor(south), math.ceil(north))}
    if not cells:
        raise ValueError("empty WGS84 bounds")
    return tuple(sorted(cells))


def plan_elevation(policy: TopographySourcePolicy,
                   indexes: Mapping[str, frozenset[tuple[int, int]]],
                   bounds: list[float] | tuple[float, ...]) -> dict[str, Any]:
    if set(indexes) != {s.id for s in policy.sources}:
        raise ValueError("all pinned source indexes are required")
    tiles, missing = [], []
    for longitude, latitude in geocells(bounds):
        source = next((s for s in policy.sources if (longitude, latitude) in indexes[s.id]), None)
        if source is None:
            missing.append([longitude, latitude])
            continue
        tiles.append({"sourceId": source.id, "datasetRelease": source.dataset_release,
                      "indexSha256": source.index_sha256, "resolutionM": source.resolution_m,
                      "cell": [longitude, latitude], "url": source.tile_url(longitude, latitude)})
    resolution = max((tile["resolutionM"] for tile in tiles), default=None)
    return {"schemaVersion": 1, "access": "free", "generationEnabled": False,
            "sourcePolicySha256": policy.sha256, "bounds": list(bounds), "tiles": tiles,
            "uncoveredCells": missing, "coverageComplete": not missing,
            "surfaceModel": "dsm", "verticalDatum": "EPSG:3855",
            "nominalResolutionM": resolution,
            "qualityMode": ("coarse-50m-v1" if resolution == 90 else "standard-20m-v1") if resolution else None,
            "minorIntervalM": (50 if resolution == 90 else 20) if resolution else None,
            "indexIntervalM": (250 if resolution == 90 else 100) if resolution else None}
