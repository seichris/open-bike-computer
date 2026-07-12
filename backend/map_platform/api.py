from __future__ import annotations

import os
import secrets
from pathlib import Path
from typing import Any

from .downloads import DownloadSigner, DownloadTokenError
from .geofabrik_sources import GeofabrikSourceProvider
from .jobs import JobClaimError, JobStore, MapJobService
from .limits import JobLimits
from .models import JobStatus
from .pipeline import MapBuildPipeline, PipelinePaths, run_job
from .source_cache import SourceCache, SourceCacheError
from .sources import SourceIndex
from .worker import MapWorker, cleanup_work_dirs, expire_ready_jobs


def create_app():
    try:
        from fastapi import Depends, FastAPI, Header, HTTPException
        from fastapi.responses import FileResponse
    except ImportError as exc:
        raise RuntimeError("Install backend API dependencies with `pip install -e backend[api]`") from exc

    repo_root = Path(os.environ.get("MAP_PLATFORM_REPO_ROOT", Path(__file__).resolve().parents[2]))
    source_index_path = Path(
        os.environ.get("MAP_PLATFORM_SOURCE_INDEX", repo_root / "backend" / "config" / "source-regions.json")
    )
    data_root = Path(os.environ.get("MAP_PLATFORM_DATA_ROOT", repo_root / "backend" / "data"))
    api_token = os.environ.get("MAP_PLATFORM_API_TOKEN")
    admin_token = os.environ.get("MAP_PLATFORM_ADMIN_TOKEN")
    download_secret = os.environ.get("MAP_PLATFORM_DOWNLOAD_SECRET") or api_token or secrets.token_urlsafe(32)
    download_signer = DownloadSigner(download_secret)
    limits = JobLimits(max_active_jobs=int(os.environ.get("MAP_PLATFORM_MAX_ACTIVE_JOBS", "25")))
    source_provider = GeofabrikSourceProvider.from_environment(data_root)
    service = MapJobService(
        SourceIndex.from_json(source_index_path, fallback_provider=source_provider),
        JobStore(data_root / "jobs"),
        limits=limits,
    )
    source_cache = SourceCache(repo_root, data_root / "source-cache.json", data_root=data_root)
    pipeline = MapBuildPipeline(
        PipelinePaths(repo_root=repo_root, work_root=data_root / "work", pack_root=data_root / "packs"),
        source_cache=source_cache,
    )

    app = FastAPI(title="Open Bike Computer Offline Map Platform", version="0.1.0")

    def require_api_token(authorization: str | None = Header(default=None)) -> None:
        if not api_token:
            return
        if authorization is None or not secrets.compare_digest(authorization, f"Bearer {api_token}"):
            raise HTTPException(status_code=401, detail="invalid API token")

    def require_admin_token(authorization: str | None = Header(default=None)) -> None:
        if not admin_token:
            raise HTTPException(status_code=503, detail="admin API is disabled")
        if authorization is None or not secrets.compare_digest(authorization, f"Bearer {admin_token}"):
            raise HTTPException(status_code=401, detail="invalid admin token")

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/v1/source-regions")
    def source_regions(includeDynamic: bool = False) -> dict[str, Any]:
        try:
            return service.source_index.to_dict(include_dynamic=includeDynamic)
        except ValueError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

    @app.post("/v1/map-jobs", dependencies=[Depends(require_api_token)])
    def create_map_job(payload: dict[str, Any]) -> dict[str, Any]:
        try:
            return service.create_job(payload).to_dict()
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.get("/v1/map-jobs", dependencies=[Depends(require_api_token)])
    def list_map_jobs(clientInstallationId: str | None = None) -> dict[str, Any]:
        if clientInstallationId is None:
            raise HTTPException(status_code=400, detail="clientInstallationId is required")
        try:
            jobs = service.list_jobs(client_installation_id=clientInstallationId)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {"jobs": [job.to_dict() for job in jobs]}

    @app.get("/v1/map-jobs/{job_id}", dependencies=[Depends(require_api_token)])
    def get_map_job(job_id: str, clientInstallationId: str | None = None) -> dict[str, Any]:
        try:
            return service.get_job_for_installation(job_id, clientInstallationId).to_dict()
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="job not found") from exc

    @app.post("/v1/map-jobs/{job_id}/run", dependencies=[Depends(require_admin_token)])
    def run_map_job(job_id: str, clientInstallationId: str | None = None) -> dict[str, Any]:
        try:
            service.get_job_for_installation(job_id, clientInstallationId)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="job not found") from exc
        try:
            return run_job(service.store, pipeline, job_id).to_dict()
        except JobClaimError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.post("/v1/map-jobs/{job_id}/cancel", dependencies=[Depends(require_api_token)])
    def cancel_map_job(job_id: str, clientInstallationId: str | None = None) -> dict[str, Any]:
        try:
            service.get_job_for_installation(job_id, clientInstallationId)
            return service.cancel_job(job_id).to_dict()
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="job not found") from exc

    @app.post("/v1/workers/run-next", dependencies=[Depends(require_admin_token)])
    def run_next_job() -> dict[str, Any]:
        result = MapWorker(service.store, pipeline).run_next()
        return {
            "workerId": result.worker_id,
            "processed": result.processed,
            "job": result.job.to_dict() if result.job else None,
        }

    @app.post("/v1/source-regions/{region_id}/cache", dependencies=[Depends(require_admin_token)])
    def cache_source_region(region_id: str) -> dict[str, Any]:
        matches = [region for region in service.source_index.all_regions(include_dynamic=True) if region.id == region_id]
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

    @app.post("/v1/maintenance/expire", dependencies=[Depends(require_admin_token)])
    def expire_map_packs(payload: dict[str, Any] | None = None) -> dict[str, int]:
        older_than_days = (payload or {}).get("olderThanDays", 30)
        if isinstance(older_than_days, bool) or not isinstance(older_than_days, int):
            raise HTTPException(status_code=400, detail="olderThanDays must be an integer")
        if not 1 <= older_than_days <= 3_650:
            raise HTTPException(status_code=400, detail="olderThanDays must be between 1 and 3650")
        return {"expired": expire_ready_jobs(service.store, older_than_days=older_than_days)}

    @app.post("/v1/maintenance/cleanup-work", dependencies=[Depends(require_admin_token)])
    def cleanup_work() -> dict[str, int]:
        return {"removed": cleanup_work_dirs(data_root / "work", service.store)}

    @app.get("/v1/map-packs/{map_id}", dependencies=[Depends(require_api_token)])
    def get_map_pack(map_id: str, clientInstallationId: str | None = None) -> dict[str, Any]:
        try:
            job = service.find_by_map_id(
                map_id,
                client_installation_id=clientInstallationId,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        if not job or job.status != JobStatus.READY:
            raise HTTPException(status_code=404, detail="map pack not found")
        return job.to_dict()

    @app.post("/v1/map-packs/{map_id}/download-url", dependencies=[Depends(require_api_token)])
    def create_download_url(
        map_id: str,
        clientInstallationId: str | None = None,
        jobId: str | None = None,
    ) -> dict[str, Any]:
        try:
            if jobId is not None:
                job = service.get_job_for_installation(jobId, clientInstallationId)
                if job.map_id != map_id:
                    job = None
            else:
                # Preserve older clients that only identify a stable map ID.
                job = service.find_by_map_id(
                    map_id,
                    client_installation_id=clientInstallationId,
                )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="map pack not ready") from exc
        if not job or job.status != JobStatus.READY or not job.pack_path:
            raise HTTPException(status_code=404, detail="map pack not ready")
        signed = download_signer.sign(map_id, job.pack_path, ttl_seconds=900)
        return {
            "mapId": map_id,
            "url": f"/v1/map-packs/{map_id}/download?jobId={job.job_id}&{signed.query()}",
            "expiresAt": signed.expires_at,
            "expiresInSeconds": 900,
        }

    @app.get("/v1/map-packs/{map_id}/download")
    def download_map_pack(
        map_id: str,
        expires: int,
        signature: str,
        jobId: str | None = None,
    ):
        if jobId is not None:
            try:
                job = service.get_job(jobId)
            except (KeyError, ValueError) as exc:
                raise HTTPException(status_code=404, detail="map pack not ready") from exc
            if job.map_id != map_id:
                raise HTTPException(status_code=404, detail="map pack not ready")
        else:
            # Preserve already-issued pre-deploy URLs for their short TTL.
            job = service.find_by_map_id(map_id, allow_owned_without_installation=True)
        if not job or job.status != JobStatus.READY or not job.pack_path:
            raise HTTPException(status_code=404, detail="map pack not ready")
        pack_path = Path(job.pack_path)
        try:
            download_signer.verify(map_id, pack_path, expires_at=expires, signature=signature)
        except DownloadTokenError as exc:
            if jobId is not None:
                raise HTTPException(status_code=403, detail=str(exc)) from exc

            # URLs issued before job-specific artifacts were deployed did not
            # include a job ID and were signed against packs/<mapId>.zip.
            legacy_pack_path = pipeline.paths.pack_root / f"{map_id}.zip"
            try:
                download_signer.verify(
                    map_id,
                    legacy_pack_path,
                    expires_at=expires,
                    signature=signature,
                )
            except DownloadTokenError as legacy_exc:
                raise HTTPException(status_code=403, detail=str(legacy_exc)) from legacy_exc
            pack_path = legacy_pack_path
        if not pack_path.exists():
            raise HTTPException(status_code=404, detail="map pack file not found")
        return FileResponse(pack_path, media_type="application/zip", filename=pack_path.name)

    return app


app = create_app()
