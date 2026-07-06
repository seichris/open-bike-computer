from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .jobs import JobStore, MapJobService
from .pipeline import MapBuildPipeline, PipelinePaths, run_job
from .source_cache import SourceCache, SourceCacheError
from .sources import SourceIndex
from .worker import MapWorker, cleanup_work_dirs, expire_ready_jobs


def create_app():
    try:
        from fastapi import FastAPI, HTTPException
    except ImportError as exc:
        raise RuntimeError("Install backend API dependencies with `pip install -e backend[api]`") from exc

    repo_root = Path(os.environ.get("MAP_PLATFORM_REPO_ROOT", Path(__file__).resolve().parents[2]))
    source_index_path = Path(
        os.environ.get("MAP_PLATFORM_SOURCE_INDEX", repo_root / "backend" / "config" / "source-regions.json")
    )
    data_root = Path(os.environ.get("MAP_PLATFORM_DATA_ROOT", repo_root / "backend" / "data"))
    service = MapJobService(SourceIndex.from_json(source_index_path), JobStore(data_root / "jobs"))
    source_cache = SourceCache(repo_root, data_root / "source-cache.json", data_root=data_root)
    pipeline = MapBuildPipeline(
        PipelinePaths(repo_root=repo_root, work_root=data_root / "work", pack_root=data_root / "packs"),
        source_cache=source_cache,
    )

    app = FastAPI(title="Open Bike Computer Offline Map Platform", version="0.1.0")

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/v1/source-regions")
    def source_regions() -> dict[str, Any]:
        return service.source_index.to_dict()

    @app.post("/v1/map-jobs")
    def create_map_job(payload: dict[str, Any]) -> dict[str, Any]:
        try:
            return service.create_job(payload).to_dict()
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.get("/v1/map-jobs")
    def list_map_jobs() -> dict[str, Any]:
        return {"jobs": [job.to_dict() for job in service.list_jobs()]}

    @app.get("/v1/map-jobs/{job_id}")
    def get_map_job(job_id: str) -> dict[str, Any]:
        try:
            return service.get_job(job_id).to_dict()
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="job not found") from exc

    @app.post("/v1/map-jobs/{job_id}/run")
    def run_map_job(job_id: str) -> dict[str, Any]:
        try:
            service.get_job(job_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="job not found") from exc
        return run_job(service.store, pipeline, job_id).to_dict()

    @app.post("/v1/map-jobs/{job_id}/cancel")
    def cancel_map_job(job_id: str) -> dict[str, Any]:
        try:
            return service.cancel_job(job_id).to_dict()
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="job not found") from exc

    @app.post("/v1/workers/run-next")
    def run_next_job() -> dict[str, Any]:
        result = MapWorker(service.store, pipeline).run_next()
        return {
            "workerId": result.worker_id,
            "processed": result.processed,
            "job": result.job.to_dict() if result.job else None,
        }

    @app.post("/v1/source-regions/{region_id}/cache")
    def cache_source_region(region_id: str) -> dict[str, Any]:
        matches = [region for region in service.source_index.regions if region.id == region_id]
        if not matches:
            raise HTTPException(status_code=404, detail="source region not found")
        try:
            cached = source_cache.ensure(matches[0], force=True)
        except SourceCacheError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
        return {
            "regionId": cached.region_id,
            "path": str(cached.path),
            "bytes": cached.bytes,
            "sha256": cached.sha256,
            "cachedAt": cached.cached_at,
        }

    @app.post("/v1/maintenance/expire")
    def expire_map_packs(payload: dict[str, Any] | None = None) -> dict[str, int]:
        older_than_days = int((payload or {}).get("olderThanDays", 30))
        return {"expired": expire_ready_jobs(service.store, older_than_days=older_than_days)}

    @app.post("/v1/maintenance/cleanup-work")
    def cleanup_work() -> dict[str, int]:
        return {"removed": cleanup_work_dirs(data_root / "work", service.store)}

    @app.get("/v1/map-packs/{map_id}")
    def get_map_pack(map_id: str) -> dict[str, Any]:
        matches = [job for job in service.list_jobs() if job.map_id == map_id]
        if not matches:
            raise HTTPException(status_code=404, detail="map pack not found")
        return matches[0].to_dict()

    @app.post("/v1/map-packs/{map_id}/download-url")
    def create_download_url(map_id: str) -> dict[str, Any]:
        matches = [job for job in service.list_jobs() if job.map_id == map_id]
        if not matches or not matches[0].pack_path:
            raise HTTPException(status_code=404, detail="map pack not ready")
        return {"mapId": map_id, "url": Path(matches[0].pack_path).as_uri(), "expiresInSeconds": 900}

    return app


app = create_app()
