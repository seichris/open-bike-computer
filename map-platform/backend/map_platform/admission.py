from __future__ import annotations

import math
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Iterable

from .map_labels import renderer_format_version
from .models import JobStatus, MapJob, NormalizedGeometry, SourceRegion


ADMISSION_POLICY_VERSION = "map-cost-v1"


class AdmissionCapacityError(RuntimeError):
    """Raised when durable public work cannot be admitted safely."""

    def __init__(
        self,
        message: str,
        *,
        code: str = "admission_capacity_exhausted",
        status_code: int = 503,
        retry_after_seconds: int = 60,
    ):
        self.code = code
        self.status_code = status_code
        self.retry_after_seconds = max(1, int(retry_after_seconds))
        super().__init__(message)

    def response_detail(self) -> dict[str, str]:
        return {"code": self.code, "message": str(self)}


@dataclass(frozen=True)
class AdmissionCost:
    units: int
    policy_version: str
    inputs: dict[str, Any]


@dataclass(frozen=True)
class AdmissionSnapshot:
    queued_cost: int
    running_cost: int
    public_queued_cost: int
    public_running_cost: int


@dataclass(frozen=True)
class AdmissionPolicy:
    max_queued_cost: int = 4_000
    max_running_cost: int = 800
    operator_reserved_queued_cost: int = 400
    operator_reserved_running_cost: int = 100
    max_installation_cost_per_window: int = 1_200
    installation_window_seconds: int = 86_400
    policy_version: str = ADMISSION_POLICY_VERSION

    def __post_init__(self) -> None:
        values = {
            "max queued cost": self.max_queued_cost,
            "max running cost": self.max_running_cost,
            "installation cost window": self.max_installation_cost_per_window,
            "installation window seconds": self.installation_window_seconds,
        }
        for name, value in values.items():
            if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
                raise ValueError(f"{name} must be a positive integer")
        reserves = (
            (
                "queued",
                self.operator_reserved_queued_cost,
                self.max_queued_cost,
            ),
            (
                "running",
                self.operator_reserved_running_cost,
                self.max_running_cost,
            ),
        )
        for name, reserved, total in reserves:
            if (
                isinstance(reserved, bool)
                or not isinstance(reserved, int)
                or reserved < 0
                or reserved >= total
            ):
                raise ValueError(
                    f"operator reserved {name} cost must be non-negative and below the total"
                )

    @classmethod
    def from_environment(cls) -> "AdmissionPolicy":
        def integer(name: str, default: int) -> int:
            raw = os.environ.get(name)
            if raw is None:
                return default
            try:
                value = int(raw)
            except ValueError as exc:
                raise ValueError(f"{name} must be an integer") from exc
            return value

        return cls(
            max_queued_cost=integer(
                "MAP_PLATFORM_MAX_QUEUED_COST",
                cls.max_queued_cost,
            ),
            max_running_cost=integer(
                "MAP_PLATFORM_MAX_RUNNING_COST",
                cls.max_running_cost,
            ),
            operator_reserved_queued_cost=integer(
                "MAP_PLATFORM_OPERATOR_RESERVED_QUEUED_COST",
                cls.operator_reserved_queued_cost,
            ),
            operator_reserved_running_cost=integer(
                "MAP_PLATFORM_OPERATOR_RESERVED_RUNNING_COST",
                cls.operator_reserved_running_cost,
            ),
            max_installation_cost_per_window=integer(
                "MAP_PLATFORM_INSTALLATION_COST_LIMIT",
                cls.max_installation_cost_per_window,
            ),
            installation_window_seconds=integer(
                "MAP_PLATFORM_INSTALLATION_COST_WINDOW_SECONDS",
                cls.installation_window_seconds,
            ),
        )

    def estimate(
        self,
        request: dict[str, Any],
        geometry: NormalizedGeometry,
        source: SourceRegion,
    ) -> AdmissionCost:
        format_version = renderer_format_version(request)
        renderer_weight = {1: 1, 2: 2, 3: 4}.get(format_version)
        if renderer_weight is None:
            raise ValueError("renderer format has no admission cost policy")

        area_units = max(1, math.ceil(geometry.area_km2 / 25.0))
        route_units = math.ceil(geometry.route_point_count / 2_000)
        vertex_units = math.ceil(geometry.vertex_count / 100)
        source_region_count = 1
        base_units = 5
        units = (
            base_units
            + area_units * renderer_weight
            + route_units
            + vertex_units
            + source_region_count
        )
        return AdmissionCost(
            units=units,
            policy_version=self.policy_version,
            inputs={
                "areaKm2": round(float(geometry.area_km2), 6),
                "areaUnits": area_units,
                "geometryMode": geometry.mode.value,
                "polygonVertexCount": geometry.vertex_count,
                "rendererFormatVersion": format_version,
                "rendererWeight": renderer_weight,
                "routePointCount": geometry.route_point_count,
                "sourceCacheState": "unknown",
                "sourceRegionCount": source_region_count,
                "sourceRegionId": source.id,
            },
        )

    def cost_for(self, job: MapJob) -> int:
        if (
            isinstance(job.admission_cost, int)
            and not isinstance(job.admission_cost, bool)
            and job.admission_cost > 0
        ):
            return job.admission_cost
        return self.estimate(job.request, job.geometry, job.source_region).units

    def snapshot(self, jobs: Iterable[MapJob]) -> AdmissionSnapshot:
        queued_cost = 0
        running_cost = 0
        public_queued_cost = 0
        public_running_cost = 0
        for job in jobs:
            queue_reservation = job.status == JobStatus.QUEUED or (
                job.status in _RUNNING_STATUSES and job.scheduler_yielded
            )
            running_reservation = (
                job.status in _RUNNING_STATUSES and not job.scheduler_yielded
            )
            if not queue_reservation and not running_reservation:
                continue
            cost = self.cost_for(job)
            is_public = job.admission_partition != "operator"
            if queue_reservation:
                queued_cost += cost
                if is_public:
                    public_queued_cost += cost
            if running_reservation:
                running_cost += cost
                if is_public:
                    public_running_cost += cost
        return AdmissionSnapshot(
            queued_cost=queued_cost,
            running_cost=running_cost,
            public_queued_cost=public_queued_cost,
            public_running_cost=public_running_cost,
        )

    def validate_create(
        self,
        candidate: MapJob,
        jobs: Iterable[MapJob],
        *,
        now: datetime | None = None,
    ) -> None:
        jobs = list(jobs)
        cost = self.cost_for(candidate)
        partition = candidate.admission_partition or "public"
        if partition not in {"public", "operator"}:
            raise ValueError("admission partition is invalid")

        snapshot = self.snapshot(jobs)
        if snapshot.queued_cost + cost > self.max_queued_cost:
            raise AdmissionCapacityError("global queued map capacity is exhausted")
        if (
            partition == "public"
            and snapshot.public_queued_cost + cost
            > self.max_queued_cost - self.operator_reserved_queued_cost
        ):
            raise AdmissionCapacityError("public queued map capacity is exhausted")

        installation_id = candidate.client_installation_id
        if partition != "public" or not installation_id:
            return
        if cost > self.max_installation_cost_per_window:
            raise AdmissionCapacityError(
                "map request exceeds the installation cost budget",
                status_code=429,
                retry_after_seconds=self.installation_window_seconds,
            )
        now = now or datetime.now(timezone.utc)
        recent_cost = 0
        oldest_recent: datetime | None = None
        for job in jobs:
            if (
                job.client_installation_id != installation_id
                or job.admission_partition == "operator"
            ):
                continue
            created = _parse_timestamp(job.created_at)
            if created is None:
                # A malformed owner record makes it unsafe to prove available
                # rolling capacity. Count it conservatively for this window.
                recent_cost += self.cost_for(job)
                continue
            age = max((now - created).total_seconds(), 0.0)
            if age >= self.installation_window_seconds:
                continue
            recent_cost += self.cost_for(job)
            if oldest_recent is None or created < oldest_recent:
                oldest_recent = created
        if recent_cost + cost > self.max_installation_cost_per_window:
            retry_after = self.installation_window_seconds
            if oldest_recent is not None:
                retry_after = max(
                    1,
                    math.ceil(
                        self.installation_window_seconds
                        - (now - oldest_recent).total_seconds()
                    ),
                )
            raise AdmissionCapacityError(
                "installation map cost budget is exhausted",
                status_code=429,
                retry_after_seconds=retry_after,
            )

    def can_start(self, candidate: MapJob, jobs: Iterable[MapJob]) -> bool:
        peers = [job for job in jobs if job.job_id != candidate.job_id]
        snapshot = self.snapshot(peers)
        cost = self.cost_for(candidate)
        if snapshot.running_cost + cost > self.max_running_cost:
            return False
        if candidate.admission_partition != "operator":
            return (
                snapshot.public_running_cost + cost
                <= self.max_running_cost - self.operator_reserved_running_cost
            )
        return True


_RUNNING_STATUSES = {
    JobStatus.VALIDATING,
    JobStatus.RESOLVING_SOURCE,
    JobStatus.EXTRACTING_PBF,
    JobStatus.CONVERTING_FEATURES,
    JobStatus.PACKAGING,
}


def _parse_timestamp(value: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)
