from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Iterable

from .models import JobStatus, MapJob


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
class QueueAdmissionPolicy:
    """Bound waiting work by count while one worker runs a build.

    Zero pending limits mean unbounded. The development channel has a generous
    count limit, while geometry and resource checks still apply.
    """

    max_pending_jobs: int
    max_pending_per_installation: int
    operator_reserved_pending_jobs: int = 0
    max_running_jobs: int = 1
    policy_version: str = "map-queue-v1"

    def __post_init__(self) -> None:
        if any(
            isinstance(value, bool) or not isinstance(value, int) or value < 0
            for value in (
                self.max_pending_jobs,
                self.max_pending_per_installation,
                self.operator_reserved_pending_jobs,
            )
        ) or (
            isinstance(self.max_running_jobs, bool)
            or not isinstance(self.max_running_jobs, int)
            or self.max_running_jobs < 1
        ):
            raise ValueError("queue limits must be non-negative integers")
        if self.operator_reserved_pending_jobs and not self.max_pending_jobs:
            raise ValueError("operator queue reserve requires a queue limit")
        if (
            self.max_pending_jobs
            and self.operator_reserved_pending_jobs >= self.max_pending_jobs
        ):
            raise ValueError("operator queue reserve must be below the queue limit")

    @classmethod
    def from_environment(cls, deployment_channel: str) -> "QueueAdmissionPolicy":
        production = deployment_channel == "production"

        def limit(name: str, default: int) -> int:
            try:
                return int(os.environ.get(name, default))
            except ValueError as exc:
                raise ValueError(f"{name} must be an integer") from exc

        return cls(
            max_pending_jobs=limit("MAP_PLATFORM_MAX_PENDING_JOBS", 12 if production else 20),
            max_pending_per_installation=limit(
                "MAP_PLATFORM_MAX_PENDING_PER_INSTALLATION", 2 if production else 0
            ),
            operator_reserved_pending_jobs=limit(
                "MAP_PLATFORM_OPERATOR_RESERVED_PENDING_JOBS", 2 if production else 0
            ),
            max_running_jobs=limit("MAP_PLATFORM_MAX_RUNNING_JOBS", 1),
        )

    def validate_create(self, candidate: MapJob, jobs: Iterable[MapJob]) -> None:
        waiting = [job for job in jobs if is_waiting(job)]
        if self.max_pending_jobs and len(waiting) >= self.max_pending_jobs:
            raise AdmissionCapacityError(
                "map queue is full", code="map_queue_full", status_code=429
            )
        if candidate.admission_partition == "operator":
            return
        public_limit = self.max_pending_jobs - self.operator_reserved_pending_jobs
        if self.max_pending_jobs and sum(
            job.admission_partition != "operator" for job in waiting
        ) >= public_limit:
            raise AdmissionCapacityError(
                "map queue is full", code="map_queue_full", status_code=429
            )
        if candidate.client_installation_id and self.max_pending_per_installation:
            owned = sum(
                job.client_installation_id == candidate.client_installation_id
                and job.admission_partition != "operator"
                for job in waiting
            )
            if owned >= self.max_pending_per_installation:
                raise AdmissionCapacityError(
                    "this installation already has pending maps",
                    code="installation_queue_full",
                    status_code=429,
                )

    def can_start(self, candidate: MapJob, jobs: Iterable[MapJob]) -> bool:
        return sum(
            job.job_id != candidate.job_id
            and job.status in _RUNNING_STATUSES
            and not job.scheduler_yielded
            for job in jobs
        ) < self.max_running_jobs


def is_waiting(job: MapJob) -> bool:
    return job.status == JobStatus.QUEUED or (
        job.status in _RUNNING_STATUSES and job.scheduler_yielded
    )


_RUNNING_STATUSES = {
    JobStatus.VALIDATING,
    JobStatus.RESOLVING_SOURCE,
    JobStatus.EXTRACTING_PBF,
    JobStatus.CONVERTING_FEATURES,
    JobStatus.PACKAGING,
}
