from __future__ import annotations

from dataclasses import dataclass

from .models import JobStatus, MapJob, NormalizedGeometry


class LimitError(ValueError):
    """Raised when a user or job would exceed configured production limits."""


ACTIVE_STATUSES = {
    JobStatus.QUEUED,
    JobStatus.VALIDATING,
    JobStatus.RESOLVING_SOURCE,
    JobStatus.EXTRACTING_PBF,
    JobStatus.CONVERTING_FEATURES,
    JobStatus.PACKAGING,
}


@dataclass(frozen=True)
class JobLimits:
    max_active_jobs: int = 25
    max_area_km2: float = 250_000.0
    max_route_points: int = 25_000
    max_polygon_vertices: int = 5_000

    def validate_geometry(self, geometry: NormalizedGeometry) -> None:
        if geometry.area_km2 > self.max_area_km2:
            raise LimitError(f"requested area exceeds limit: {geometry.area_km2:.0f} km2 > {self.max_area_km2:.0f} km2")
        if geometry.route_point_count > self.max_route_points:
            raise LimitError("route contains too many points")
        if geometry.vertex_count > self.max_polygon_vertices:
            raise LimitError("polygon contains too many vertices")

    def validate_active_jobs(self, jobs: list[MapJob]) -> None:
        active_count = sum(1 for job in jobs if job.status in ACTIVE_STATUSES)
        if active_count >= self.max_active_jobs:
            raise LimitError(f"too many active jobs: {active_count} >= {self.max_active_jobs}")
