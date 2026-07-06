from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any


class GeometryMode(str, Enum):
    CUSTOM_BBOX = "custom_bbox"
    CUSTOM_POLYGON = "custom_polygon"
    ROUTE_CORRIDOR = "route_corridor"
    CURATED_REGION = "curated_region"


class JobStatus(str, Enum):
    QUEUED = "queued"
    VALIDATING = "validating"
    RESOLVING_SOURCE = "resolving_source"
    EXTRACTING_PBF = "extracting_pbf"
    CONVERTING_FEATURES = "converting_features"
    PACKAGING = "packaging"
    READY = "ready"
    FAILED = "failed"
    EXPIRED = "expired"


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True)
class Bounds:
    min_lon: float
    min_lat: float
    max_lon: float
    max_lat: float

    @classmethod
    def from_list(cls, values: list[float] | tuple[float, float, float, float]) -> "Bounds":
        if len(values) != 4:
            raise ValueError("bounds must contain [minLon, minLat, maxLon, maxLat]")
        return cls(float(values[0]), float(values[1]), float(values[2]), float(values[3]))

    def to_list(self) -> list[float]:
        return [self.min_lon, self.min_lat, self.max_lon, self.max_lat]


@dataclass(frozen=True)
class NormalizedGeometry:
    mode: GeometryMode
    bounds: Bounds
    area_km2: float
    vertex_count: int
    geometry: dict[str, Any] | None = None
    route_point_count: int = 0
    corridor_width_m: float | None = None

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "mode": self.mode.value,
            "bounds": self.bounds.to_list(),
            "areaKm2": self.area_km2,
            "vertexCount": self.vertex_count,
            "routePointCount": self.route_point_count,
        }
        if self.geometry is not None:
            data["geometry"] = self.geometry
        if self.corridor_width_m is not None:
            data["corridorWidthM"] = self.corridor_width_m
        return data


@dataclass(frozen=True)
class SourceRegion:
    id: str
    provider: str
    name: str
    url: str
    bounds: Bounds
    local_path: str | None = None
    published_at: str | None = None
    checksum: str | None = None
    license: str = "ODbL-1.0"

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "SourceRegion":
        return cls(
            id=str(data["id"]),
            provider=str(data["provider"]),
            name=str(data["name"]),
            url=str(data["url"]),
            bounds=Bounds.from_list(data["bounds"]),
            local_path=data.get("localPath"),
            published_at=data.get("publishedAt"),
            checksum=data.get("checksum"),
            license=str(data.get("license", "ODbL-1.0")),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "provider": self.provider,
            "name": self.name,
            "url": self.url,
            "bounds": self.bounds.to_list(),
            "localPath": self.local_path,
            "publishedAt": self.published_at,
            "checksum": self.checksum,
            "license": self.license,
        }


@dataclass
class MapJob:
    job_id: str
    status: JobStatus
    request: dict[str, Any]
    geometry: NormalizedGeometry
    source_region: SourceRegion
    created_at: str = field(default_factory=utc_now_iso)
    updated_at: str = field(default_factory=utc_now_iso)
    error: str | None = None
    map_id: str | None = None
    pack_path: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "jobId": self.job_id,
            "status": self.status.value,
            "request": self.request,
            "geometry": self.geometry.to_dict(),
            "sourceRegion": self.source_region.to_dict(),
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
            "error": self.error,
            "mapId": self.map_id,
            "packPath": self.pack_path,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "MapJob":
        geometry_data = data["geometry"]
        geometry = NormalizedGeometry(
            mode=GeometryMode(geometry_data["mode"]),
            bounds=Bounds.from_list(geometry_data["bounds"]),
            area_km2=float(geometry_data["areaKm2"]),
            vertex_count=int(geometry_data["vertexCount"]),
            geometry=geometry_data.get("geometry"),
            route_point_count=int(geometry_data.get("routePointCount", 0)),
            corridor_width_m=geometry_data.get("corridorWidthM"),
        )
        return cls(
            job_id=str(data["jobId"]),
            status=JobStatus(data["status"]),
            request=dict(data["request"]),
            geometry=geometry,
            source_region=SourceRegion.from_dict(data["sourceRegion"]),
            created_at=str(data["createdAt"]),
            updated_at=str(data["updatedAt"]),
            error=data.get("error"),
            map_id=data.get("mapId"),
            pack_path=data.get("packPath"),
        )

