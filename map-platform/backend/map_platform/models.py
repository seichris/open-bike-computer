from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any

from .artifacts import ArtifactRecord


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
    CANCELLED = "cancelled"


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


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
    preview_geometry: dict[str, Any] | None = None

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
            preview_geometry=data.get("previewGeometry"),
        )

    def to_dict(self, *, include_internal: bool = False) -> dict[str, Any]:
        result = {
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
        if include_internal and self.preview_geometry is not None:
            result["previewGeometry"] = self.preview_geometry
        return result


@dataclass(frozen=True)
class MapDownloadReceipt:
    receipt_id: str
    artifact_format: str
    bytes: int
    downloaded_at: str
    sha256: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "receiptId": self.receipt_id,
            "artifactFormat": self.artifact_format,
            "bytes": self.bytes,
            "sha256": self.sha256,
            "downloadedAt": self.downloaded_at,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "MapDownloadReceipt":
        return cls(
            receipt_id=str(data["receiptId"]),
            artifact_format=str(data["artifactFormat"]),
            bytes=int(data["bytes"]),
            sha256=data.get("sha256"),
            downloaded_at=str(data["downloadedAt"]),
        )


@dataclass
class MapJob:
    job_id: str
    status: JobStatus
    request: dict[str, Any]
    geometry: NormalizedGeometry
    source_region: SourceRegion
    client_installation_id: str | None = None
    client_request_id: str | None = None
    install_on_device: bool = False
    created_at: str = field(default_factory=utc_now_iso)
    updated_at: str = field(default_factory=utc_now_iso)
    error: str | None = None
    error_code: str | None = None
    map_id: str | None = None
    pack_path: str | None = None
    pack_bytes: int | None = None
    artifacts: list[ArtifactRecord] = field(default_factory=list)
    artifact_metrics: dict[str, Any] | None = None
    user_label: str | None = None
    build_cache_key: str | None = None
    build_compatibility_key: str | None = None
    reuse_strategy: str | None = None
    reuse_source_job_id: str | None = None
    download_receipts: list[MapDownloadReceipt] = field(default_factory=list)
    pending_artifact_keys: list[str] = field(default_factory=list)
    artifact_gc_keys: list[str] = field(default_factory=list)
    attempts: int = 0
    max_attempts: int = 3
    worker_id: str | None = None
    started_at: str | None = None
    finished_at: str | None = None
    progress_completed: int | None = None
    progress_total: int | None = None
    events: list[dict[str, Any]] = field(default_factory=list)

    @property
    def artifact_display_name(self) -> str:
        """Return the immutable pack name available when the job is created."""
        requested = self.request.get("displayName")
        if isinstance(requested, str) and (trimmed := requested.strip()):
            return trimmed
        if trimmed_source := self.source_region.name.strip():
            return trimmed_source
        return "Offline map"

    def to_dict(self, *, include_internal: bool = False) -> dict[str, Any]:
        result = {
            "jobId": self.job_id,
            "status": self.status.value,
            "request": self.request,
            "geometry": self.geometry.to_dict(),
            "sourceRegion": self.source_region.to_dict(include_internal=include_internal),
            "clientInstallationId": self.client_installation_id,
            "clientRequestId": self.client_request_id,
            "installOnDevice": self.install_on_device,
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
            "error": self.error,
            "errorCode": self.error_code,
            "mapId": self.map_id,
            "packPath": self.pack_path,
            "packBytes": self.pack_bytes,
            "artifacts": [artifact.to_dict() for artifact in self.artifacts],
            "artifactMetrics": self.artifact_metrics,
            "userLabel": self.user_label,
            "reuseStrategy": self.reuse_strategy,
            "downloadCount": len(self.download_receipts),
            "firstDownloadedAt": (
                self.download_receipts[0].downloaded_at
                if self.download_receipts
                else None
            ),
            "lastDownloadedAt": (
                self.download_receipts[-1].downloaded_at
                if self.download_receipts
                else None
            ),
            "attempts": self.attempts,
            "maxAttempts": self.max_attempts,
            "workerId": self.worker_id,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "progress": self.progress(),
            "events": self.events,
            "phaseTimings": self.phase_timings(),
        }
        if include_internal:
            result["buildCacheKey"] = self.build_cache_key
            result["buildCompatibilityKey"] = self.build_compatibility_key
            result["reuseSourceJobId"] = self.reuse_source_job_id
            result["downloadReceipts"] = [
                receipt.to_dict() for receipt in self.download_receipts
            ]
            result["pendingArtifactKeys"] = self.pending_artifact_keys
            result["artifactGcKeys"] = self.artifact_gc_keys
        return result

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
            client_installation_id=data.get("clientInstallationId") or data.get("request", {}).get("clientInstallationId"),
            client_request_id=data.get("clientRequestId") or data.get("request", {}).get("clientRequestId"),
            install_on_device=bool(data.get("installOnDevice", data.get("request", {}).get("installOnDevice", False))),
            created_at=str(data["createdAt"]),
            updated_at=str(data["updatedAt"]),
            error=data.get("error"),
            error_code=data.get("errorCode"),
            map_id=data.get("mapId"),
            pack_path=data.get("packPath"),
            pack_bytes=data.get("packBytes"),
            artifacts=[ArtifactRecord.from_dict(value) for value in data.get("artifacts", [])],
            artifact_metrics=dict(data["artifactMetrics"]) if data.get("artifactMetrics") else None,
            user_label=data.get("userLabel"),
            build_cache_key=data.get("buildCacheKey"),
            build_compatibility_key=data.get("buildCompatibilityKey"),
            reuse_strategy=data.get("reuseStrategy"),
            reuse_source_job_id=data.get("reuseSourceJobId"),
            download_receipts=[
                MapDownloadReceipt.from_dict(value)
                for value in data.get("downloadReceipts", [])
            ],
            pending_artifact_keys=[str(value) for value in data.get("pendingArtifactKeys", [])],
            artifact_gc_keys=[str(value) for value in data.get("artifactGcKeys", [])],
            attempts=int(data.get("attempts", 0)),
            max_attempts=int(data.get("maxAttempts", 3)),
            worker_id=data.get("workerId"),
            started_at=data.get("startedAt"),
            finished_at=data.get("finishedAt"),
            progress_completed=_progress_value(data.get("progress"), "completedBlocks"),
            progress_total=_progress_value(data.get("progress"), "totalBlocks"),
            events=list(data.get("events", [])),
        )

    def progress(self) -> dict[str, Any] | None:
        if self.progress_completed is None or self.progress_total is None or self.progress_total <= 0:
            return None
        completed = max(0, min(self.progress_completed, self.progress_total))
        return {
            "completedBlocks": completed,
            "totalBlocks": self.progress_total,
            "fraction": completed / self.progress_total,
        }

    def phase_timings(self) -> list[dict[str, Any]]:
        transitions: list[tuple[str, str]] = []
        if self.started_at:
            transitions.append((JobStatus.VALIDATING.value, self.started_at))
        for event in self.events:
            status = event.get("status")
            at = event.get("at")
            if isinstance(status, str) and isinstance(at, str):
                if not transitions or transitions[-1] != (status, at):
                    transitions.append((status, at))

        timings: list[dict[str, Any]] = []
        for index, (status, started_at) in enumerate(transitions):
            finished_at = transitions[index + 1][1] if index + 1 < len(transitions) else self.finished_at
            timing: dict[str, Any] = {
                "status": status,
                "startedAt": started_at,
                "finishedAt": finished_at,
            }
            if finished_at:
                duration = _duration_seconds(started_at, finished_at)
                if duration is not None:
                    timing["durationSeconds"] = duration
            timings.append(timing)
        return timings


def _parse_utc(value: str) -> datetime | None:
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _progress_value(progress: Any, key: str) -> int | None:
    if not isinstance(progress, dict) or progress.get(key) is None:
        return None
    try:
        return int(progress[key])
    except (TypeError, ValueError):
        return None


def _duration_seconds(started_at: str, finished_at: str) -> float | None:
    start = _parse_utc(started_at)
    finish = _parse_utc(finished_at)
    if start is None or finish is None:
        return None
    return max((finish - start).total_seconds(), 0)
