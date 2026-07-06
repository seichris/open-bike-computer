from __future__ import annotations

import json
import re
import uuid
from pathlib import Path
from typing import Any

from .geometry import GeometryError, normalize_geometry
from .models import JobStatus, MapJob, utc_now_iso
from .sources import SourceIndex, SourceResolutionError


class JobStore:
    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def save(self, job: MapJob) -> None:
        path = self._path(job.job_id)
        path.write_text(json.dumps(job.to_dict(), indent=2, sort_keys=True) + "\n")

    def get(self, job_id: str) -> MapJob:
        path = self._path(job_id)
        if not path.exists():
            raise KeyError(job_id)
        return MapJob.from_dict(json.loads(path.read_text()))

    def list(self) -> list[MapJob]:
        return [MapJob.from_dict(json.loads(path.read_text())) for path in sorted(self.root.glob("*.json"))]

    def update_status(
        self,
        job_id: str,
        status: JobStatus,
        *,
        error: str | None = None,
        map_id: str | None = None,
        pack_path: str | None = None,
    ) -> MapJob:
        job = self.get(job_id)
        job.status = status
        job.updated_at = utc_now_iso()
        job.error = error
        if map_id is not None:
            job.map_id = map_id
        if pack_path is not None:
            job.pack_path = pack_path
        self.save(job)
        return job

    def _path(self, job_id: str) -> Path:
        if not re.match(r"^[a-zA-Z0-9_-]+$", job_id):
            raise ValueError("invalid job id")
        return self.root / f"{job_id}.json"


class MapJobService:
    def __init__(self, source_index: SourceIndex, store: JobStore):
        self.source_index = source_index
        self.store = store

    def create_job(self, request: dict[str, Any]) -> MapJob:
        try:
            geometry = normalize_geometry(request)
            source = self.source_index.resolve_for_bounds(geometry.bounds)
        except (GeometryError, SourceResolutionError) as exc:
            raise ValueError(str(exc)) from exc
        job = MapJob(
            job_id=self._new_job_id(),
            status=JobStatus.QUEUED,
            request=dict(request),
            geometry=geometry,
            source_region=source,
        )
        self.store.save(job)
        return job

    def get_job(self, job_id: str) -> MapJob:
        return self.store.get(job_id)

    def list_jobs(self) -> list[MapJob]:
        return self.store.list()

    def _new_job_id(self) -> str:
        return uuid.uuid4().hex[:20]

