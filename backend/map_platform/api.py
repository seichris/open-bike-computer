from __future__ import annotations

import os
import secrets
import time
from pathlib import Path
from typing import Any

from .artifacts import BIKE_MAP_STREAM_FORMAT, create_artifact_store_from_environment
from .downloads import DownloadSigner, DownloadTokenError
from .geofabrik_sources import GeofabrikSourceProvider
from .installations import InstallationCredentialError, InstallationCredentialStore
from .jobs import JobClaimError, JobStore, MapJobService
from .limits import JobLimits
from .map_signing import map_stream_generation_enabled
from .map_stream_hardware_requirements import load_hardware_requirements
from .map_stream_rollout import (
    MapStreamRolloutMode,
    MapStreamRolloutPolicy,
    configured_map_stream_rollout_mode,
    load_approved_promotions,
    parse_map_stream_app_build,
    parse_map_stream_app_build_sha256,
    parse_map_stream_app_git_sha,
    parse_map_stream_trust_capabilities,
)
from .map_stream_trust_registry import trusted_key_fingerprints
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
    artifact_store = create_artifact_store_from_environment(
        data_root,
        credential_scope="api",
    )
    installation_secret = os.environ.get("MAP_PLATFORM_INSTALLATION_SECRET", "")
    previous_installation_secrets = [
        value
        for value in os.environ.get(
            "MAP_PLATFORM_INSTALLATION_PREVIOUS_SECRETS",
            "",
        ).split(",")
        if value
    ]
    installation_store = InstallationCredentialStore(
        installation_secret,
        previous_secrets=previous_installation_secrets,
    )
    rollout_approvals_path = Path(
        os.environ.get(
            "MAP_PLATFORM_MAP_STREAM_ROLLOUT_APPROVALS",
            repo_root / "config" / "map-stream-rollout-approvals.json",
        )
    )
    rollout_mode = configured_map_stream_rollout_mode()
    rollout_controls: dict[str, Any] = {}
    if rollout_mode in {
        MapStreamRolloutMode.PERCENTAGE,
        MapStreamRolloutMode.ALL,
    }:
        map_stream_trust_path = Path(
            os.environ.get(
                "MAP_PLATFORM_MAP_STREAM_TRUST_REGISTRY",
                repo_root / "config" / "map-stream-trust.json",
            )
        )
        hardware_requirements_path = Path(
            os.environ.get(
                "MAP_PLATFORM_MAP_STREAM_HARDWARE_REQUIREMENTS",
                repo_root / "config" / "map-stream-hardware-gate.json",
            )
        )
        hardware_requirements = load_hardware_requirements(
            hardware_requirements_path
        )
        rollout_controls = {
            "approved_promotions_by_id": load_approved_promotions(
                rollout_approvals_path
            ),
            "trusted_signing_keys": trusted_key_fingerprints(
                map_stream_trust_path
            ),
            "current_requirements_sha256": hardware_requirements.sha256,
        }
    map_stream_rollout = MapStreamRolloutPolicy.from_environment(
        **rollout_controls
    )
    inline_worker_enabled = os.environ.get(
        "MAP_PLATFORM_INLINE_WORKER_ENABLED",
        "0",
    ).strip().lower() in {"1", "true", "yes"}
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
        source_preview_geometry_resolver=(
            source_provider.preview_geometry_for_source
            if source_provider is not None
            else None
        ),
    )

    app = FastAPI(title="Open Bike Computer Offline Map Platform", version="0.1.0")
    app.state.artifact_store = artifact_store
    app.state.installation_store = installation_store
    app.state.map_stream_rollout = map_stream_rollout

    def public_job(
        job,
        installation_id: str | None,
        client_trust_capabilities: frozenset[tuple[str, str]],
        client_app_build: str | None,
        client_app_git_sha: str | None,
        client_app_build_sha256: str | None,
    ) -> dict[str, Any]:
        result = job.to_dict()
        public_artifacts: list[dict[str, Any]] = []
        stream_allowed = False
        for artifact in result.get("artifacts", []):
            if artifact.get("format") != BIKE_MAP_STREAM_FORMAT:
                public_artifacts.append(artifact)
                continue
            if not map_stream_rollout.allows_artifact(
                installation_id,
                artifact.get("signatureKeyId"),
                artifact.get("signatureKeySha256"),
                artifact.get("producerBuildSha256"),
                artifact.get("producerImageDigest"),
                client_trust_capabilities,
                client_app_build,
                client_app_git_sha,
                client_app_build_sha256,
            ):
                continue
            stream_allowed = True
            public_artifacts.append(
                {
                    **artifact,
                    **map_stream_rollout.artifact_identity_requirements(
                        client_app_build,
                        client_app_git_sha,
                        client_app_build_sha256,
                    ),
                }
            )
        result["artifacts"] = public_artifacts
        if not stream_allowed and isinstance(result.get("artifactMetrics"), dict):
            result["artifactMetrics"] = {
                key: value
                for key, value in result["artifactMetrics"].items()
                if not key.startswith("stream")
            } or None
        return result

    def client_map_stream_trust_capabilities(
        header_value: str | None,
    ) -> frozenset[tuple[str, str]]:
        try:
            return parse_map_stream_trust_capabilities(header_value)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    def client_map_stream_app_identity(
        build_header: str | None,
        git_sha_header: str | None,
        build_sha256_header: str | None,
    ) -> tuple[str | None, str | None, str | None]:
        try:
            identity = (
                parse_map_stream_app_build(build_header),
                parse_map_stream_app_git_sha(git_sha_header),
                parse_map_stream_app_build_sha256(build_sha256_header),
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        if any(identity) and not all(identity):
            raise HTTPException(
                status_code=400,
                detail="map stream app identity headers are incomplete",
            )
        return identity

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

    def verify_registered_installation(
        installation_id: str | None,
        installation_token: str | None,
        *,
        required: bool = False,
    ) -> None:
        if installation_id is None:
            if required:
                raise HTTPException(status_code=401, detail="installation credential is required")
            return
        if not isinstance(installation_id, str):
            if required:
                raise HTTPException(status_code=401, detail="installation credential is required")
            return
        try:
            registered = installation_store.is_registered(installation_id)
        except InstallationCredentialError as exc:
            if not required:
                return
            raise HTTPException(status_code=401, detail=str(exc)) from exc
        if required or registered:
            try:
                installation_store.verify(installation_id, installation_token)
            except InstallationCredentialError as exc:
                raise HTTPException(status_code=401, detail=str(exc)) from exc

    @app.get("/healthz")
    def healthz() -> dict[str, Any]:
        return {
            "status": "ok",
            "mapStreamRollout": map_stream_rollout.public_summary(),
        }

    @app.post("/v1/installations", dependencies=[Depends(require_api_token)])
    def create_installation() -> dict[str, str]:
        installation_id, token = installation_store.issue()
        return {
            "clientInstallationId": installation_id,
            "clientInstallationToken": token,
        }

    @app.get("/v1/source-regions")
    def source_regions(includeDynamic: bool = False) -> dict[str, Any]:
        try:
            return service.source_index.to_dict(include_dynamic=includeDynamic)
        except ValueError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

    @app.post("/v1/map-jobs", dependencies=[Depends(require_api_token)])
    def create_map_job(
        payload: dict[str, Any],
        x_installation_token: str | None = Header(
            default=None,
            alias="X-Installation-Token",
        ),
        x_map_stream_trust: str | None = Header(
            default=None,
            alias="X-Map-Stream-Trust",
        ),
        x_map_stream_app_build: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build",
        ),
        x_map_stream_app_git_sha: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Git-Sha",
        ),
        x_map_stream_app_build_sha256: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build-Sha256",
        ),
    ) -> dict[str, Any]:
        try:
            trust_capabilities = client_map_stream_trust_capabilities(x_map_stream_trust)
            app_build, app_git_sha, app_build_sha256 = client_map_stream_app_identity(
                x_map_stream_app_build,
                x_map_stream_app_git_sha,
                x_map_stream_app_build_sha256,
            )
            verify_registered_installation(
                payload.get("clientInstallationId"),
                x_installation_token,
            )
            return public_job(
                service.create_job(payload),
                payload.get("clientInstallationId"),
                trust_capabilities,
                app_build,
                app_git_sha,
                app_build_sha256,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.get("/v1/map-jobs", dependencies=[Depends(require_api_token)])
    def list_map_jobs(
        clientInstallationId: str | None = None,
        x_installation_token: str | None = Header(
            default=None,
            alias="X-Installation-Token",
        ),
        x_map_stream_trust: str | None = Header(
            default=None,
            alias="X-Map-Stream-Trust",
        ),
        x_map_stream_app_build: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build",
        ),
        x_map_stream_app_git_sha: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Git-Sha",
        ),
        x_map_stream_app_build_sha256: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build-Sha256",
        ),
    ) -> dict[str, Any]:
        if clientInstallationId is None:
            raise HTTPException(status_code=400, detail="clientInstallationId is required")
        try:
            trust_capabilities = client_map_stream_trust_capabilities(x_map_stream_trust)
            app_build, app_git_sha, app_build_sha256 = client_map_stream_app_identity(
                x_map_stream_app_build,
                x_map_stream_app_git_sha,
                x_map_stream_app_build_sha256,
            )
            verify_registered_installation(clientInstallationId, x_installation_token)
            jobs = service.list_jobs(client_installation_id=clientInstallationId)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {
            "jobs": [
                public_job(
                    job,
                    clientInstallationId,
                    trust_capabilities,
                    app_build,
                    app_git_sha,
                    app_build_sha256,
                )
                for job in jobs
            ]
        }

    @app.get("/v1/map-jobs/{job_id}", dependencies=[Depends(require_api_token)])
    def get_map_job(
        job_id: str,
        clientInstallationId: str | None = None,
        x_installation_token: str | None = Header(
            default=None,
            alias="X-Installation-Token",
        ),
        x_map_stream_trust: str | None = Header(
            default=None,
            alias="X-Map-Stream-Trust",
        ),
        x_map_stream_app_build: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build",
        ),
        x_map_stream_app_git_sha: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Git-Sha",
        ),
        x_map_stream_app_build_sha256: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build-Sha256",
        ),
    ) -> dict[str, Any]:
        try:
            trust_capabilities = client_map_stream_trust_capabilities(x_map_stream_trust)
            app_build, app_git_sha, app_build_sha256 = client_map_stream_app_identity(
                x_map_stream_app_build,
                x_map_stream_app_git_sha,
                x_map_stream_app_build_sha256,
            )
            verify_registered_installation(clientInstallationId, x_installation_token)
            return public_job(
                service.get_job_for_installation(job_id, clientInstallationId),
                clientInstallationId,
                trust_capabilities,
                app_build,
                app_git_sha,
                app_build_sha256,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="job not found") from exc

    @app.post("/v1/map-jobs/{job_id}/run", dependencies=[Depends(require_admin_token)])
    def run_map_job(job_id: str, clientInstallationId: str | None = None) -> dict[str, Any]:
        if not inline_worker_enabled or map_stream_generation_enabled():
            raise HTTPException(status_code=503, detail="inline map workers are disabled")
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
    def cancel_map_job(
        job_id: str,
        clientInstallationId: str | None = None,
        x_installation_token: str | None = Header(
            default=None,
            alias="X-Installation-Token",
        ),
        x_map_stream_trust: str | None = Header(
            default=None,
            alias="X-Map-Stream-Trust",
        ),
        x_map_stream_app_build: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build",
        ),
        x_map_stream_app_git_sha: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Git-Sha",
        ),
        x_map_stream_app_build_sha256: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build-Sha256",
        ),
    ) -> dict[str, Any]:
        try:
            trust_capabilities = client_map_stream_trust_capabilities(x_map_stream_trust)
            app_build, app_git_sha, app_build_sha256 = client_map_stream_app_identity(
                x_map_stream_app_build,
                x_map_stream_app_git_sha,
                x_map_stream_app_build_sha256,
            )
            verify_registered_installation(clientInstallationId, x_installation_token)
            service.get_job_for_installation(job_id, clientInstallationId)
            return public_job(
                service.cancel_job(job_id),
                clientInstallationId,
                trust_capabilities,
                app_build,
                app_git_sha,
                app_build_sha256,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="job not found") from exc

    @app.post("/v1/workers/run-next", dependencies=[Depends(require_admin_token)])
    def run_next_job() -> dict[str, Any]:
        if not inline_worker_enabled or map_stream_generation_enabled():
            raise HTTPException(status_code=503, detail="inline map workers are disabled")
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
        return {
            "expired": expire_ready_jobs(
                service.store,
                older_than_days=older_than_days,
                artifact_store=None,
            )
        }

    @app.post("/v1/maintenance/cleanup-work", dependencies=[Depends(require_admin_token)])
    def cleanup_work() -> dict[str, int]:
        return {"removed": cleanup_work_dirs(data_root / "work", service.store)}

    @app.get("/v1/map-packs/{map_id}", dependencies=[Depends(require_api_token)])
    def get_map_pack(
        map_id: str,
        clientInstallationId: str | None = None,
        x_installation_token: str | None = Header(
            default=None,
            alias="X-Installation-Token",
        ),
        x_map_stream_trust: str | None = Header(
            default=None,
            alias="X-Map-Stream-Trust",
        ),
        x_map_stream_app_build: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build",
        ),
        x_map_stream_app_git_sha: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Git-Sha",
        ),
        x_map_stream_app_build_sha256: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build-Sha256",
        ),
    ) -> dict[str, Any]:
        try:
            trust_capabilities = client_map_stream_trust_capabilities(x_map_stream_trust)
            app_build, app_git_sha, app_build_sha256 = client_map_stream_app_identity(
                x_map_stream_app_build,
                x_map_stream_app_git_sha,
                x_map_stream_app_build_sha256,
            )
            verify_registered_installation(clientInstallationId, x_installation_token)
            job = service.find_by_map_id(
                map_id,
                client_installation_id=clientInstallationId,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        if not job or job.status != JobStatus.READY:
            raise HTTPException(status_code=404, detail="map pack not found")
        return public_job(
            job,
            clientInstallationId,
            trust_capabilities,
            app_build,
            app_git_sha,
            app_build_sha256,
        )

    @app.post("/v1/map-packs/{map_id}/download-url", dependencies=[Depends(require_api_token)])
    def create_download_url(
        map_id: str,
        clientInstallationId: str | None = None,
        jobId: str | None = None,
        x_installation_token: str | None = Header(
            default=None,
            alias="X-Installation-Token",
        ),
    ) -> dict[str, Any]:
        try:
            verify_registered_installation(clientInstallationId, x_installation_token)
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

    @app.post(
        "/v1/map-packs/{map_id}/artifacts/{artifact_format}/download-url",
        dependencies=[Depends(require_api_token)],
    )
    def create_artifact_download_url(
        map_id: str,
        artifact_format: str,
        clientInstallationId: str | None = None,
        jobId: str | None = None,
        signedManifestReceipt: str | None = None,
        x_installation_token: str | None = Header(
            default=None,
            alias="X-Installation-Token",
        ),
        x_map_stream_trust: str | None = Header(
            default=None,
            alias="X-Map-Stream-Trust",
        ),
        x_map_stream_app_build: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build",
        ),
        x_map_stream_app_git_sha: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Git-Sha",
        ),
        x_map_stream_app_build_sha256: str | None = Header(
            default=None,
            alias="X-Map-Stream-App-Build-Sha256",
        ),
    ) -> dict[str, Any]:
        try:
            trust_capabilities = client_map_stream_trust_capabilities(x_map_stream_trust)
            app_build, app_git_sha, app_build_sha256 = client_map_stream_app_identity(
                x_map_stream_app_build,
                x_map_stream_app_git_sha,
                x_map_stream_app_build_sha256,
            )
            verify_registered_installation(
                clientInstallationId,
                x_installation_token,
                required=True,
            )
            if jobId is not None:
                job = service.get_job_for_installation(jobId, clientInstallationId)
                if job.map_id != map_id:
                    job = None
            else:
                job = service.find_by_map_id(
                    map_id,
                    client_installation_id=clientInstallationId,
                )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="map artifact not ready") from exc
        if not job or job.status != JobStatus.READY:
            raise HTTPException(status_code=404, detail="map artifact not ready")
        if (
            artifact_format == BIKE_MAP_STREAM_FORMAT
            and not map_stream_rollout.includes(clientInstallationId)
        ):
            raise HTTPException(status_code=404, detail="map artifact not ready")
        if artifact_format == BIKE_MAP_STREAM_FORMAT and signedManifestReceipt is None:
            raise HTTPException(
                status_code=400,
                detail="signedManifestReceipt is required for map stream URL refresh",
            )
        artifact = next(
            (
                value
                for value in job.artifacts
                if value.format == artifact_format
                and (
                    signedManifestReceipt is None
                    or value.signed_manifest_receipt == signedManifestReceipt
                )
            ),
            None,
        )
        if artifact is None:
            raise HTTPException(status_code=404, detail="map artifact not ready")
        if (
            artifact_format == BIKE_MAP_STREAM_FORMAT
            and not map_stream_rollout.allows_artifact(
                clientInstallationId,
                artifact.signature_key_id,
                artifact.signature_key_sha256,
                artifact.producer_build_sha256,
                artifact.producer_image_digest,
                trust_capabilities,
                app_build,
                app_git_sha,
                app_build_sha256,
            )
        ):
            raise HTTPException(status_code=404, detail="map artifact not ready")
        expires_in_seconds = 900
        external_url = artifact_store.create_download_url(
            artifact.object_key,
            expires_in_seconds=expires_in_seconds,
            filename=artifact.filename,
            media_type=artifact.media_type,
        )
        if external_url is None:
            signed = download_signer.sign(
                map_id,
                artifact.object_key,
                ttl_seconds=expires_in_seconds,
            )
            external_url = (
                f"/v1/map-packs/{map_id}/artifacts/{artifact.format}/download"
                f"?jobId={job.job_id}&{signed.query()}"
            )
            expires_at = signed.expires_at
        else:
            expires_at = int(time.time()) + expires_in_seconds
        return {
            **artifact.to_dict(),
            **(
                map_stream_rollout.artifact_identity_requirements(
                    app_build,
                    app_git_sha,
                    app_build_sha256,
                )
                if artifact_format == BIKE_MAP_STREAM_FORMAT
                else {}
            ),
            "url": external_url,
            "expiresAt": expires_at,
            "expiresInSeconds": expires_in_seconds,
        }

    @app.get("/v1/map-packs/{map_id}/artifacts/{artifact_format}/download")
    def download_map_artifact(
        map_id: str,
        artifact_format: str,
        jobId: str,
        expires: int,
        signature: str,
    ):
        try:
            job = service.get_job(jobId)
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=404, detail="map artifact not ready") from exc
        if job.map_id != map_id or job.status != JobStatus.READY:
            raise HTTPException(status_code=404, detail="map artifact not ready")
        artifact = next(
            (value for value in job.artifacts if value.format == artifact_format),
            None,
        )
        if artifact is None:
            raise HTTPException(status_code=404, detail="map artifact not ready")
        try:
            download_signer.verify(
                map_id,
                artifact.object_key,
                expires_at=expires,
                signature=signature,
            )
        except DownloadTokenError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        artifact_path = artifact_store.local_path(artifact.object_key)
        if artifact_path is None:
            raise HTTPException(status_code=404, detail="map artifact file not found")
        return FileResponse(
            artifact_path,
            media_type=artifact.media_type,
            filename=artifact.filename,
        )

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
