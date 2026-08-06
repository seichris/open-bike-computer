from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

from .artifacts import create_artifact_store_from_environment
from .geofabrik_sources import GeofabrikSourceProvider
from .jobs import ArtifactGarbageCollectionError, JobStore, MapJobService
from .map_buildings import (
    building_target3_generation_allowlist,
    building_target3_generation_enabled,
)
from .map_labels import label_target2_generation_enabled
from .map_signing import load_map_artifact_signer_from_environment
from .monitoring import DEFAULT_MONITORING_RETENTION_DAYS, MapMonitoringStore
from .map_stream_build_identity import (
    image_digest_from_reference,
    verify_map_stream_build_identity,
)
from .pipeline import MapBuildPipeline, PipelinePaths, run_job
from .rate_limits import purge_expired_rate_limits
from .source_cache import SourceCache, default_backend_data_root
from .sources import SourceIndex
from .worker import (
    ExpiredArtifactCleanupError,
    MapWorker,
    WorkDirectoryCleanupError,
    cleanup_work_dirs,
    expire_ready_jobs,
)


class MaintenanceIterationError(RuntimeError):
    def __init__(self, result: dict[str, object]):
        super().__init__("one or more maintenance tasks failed")
        self.result = result


def _safe_error_summary(exc: Exception) -> dict[str, object]:
    chain: list[Exception] = []
    current: BaseException | None = exc
    seen: set[int] = set()
    while isinstance(current, Exception) and id(current) not in seen:
        seen.add(id(current))
        chain.append(current)
        current = current.__cause__ or current.__context__

    category = "external_error"
    if any(isinstance(item, PermissionError) for item in chain):
        category = "permission_denied"
    elif any(isinstance(item, FileNotFoundError) for item in chain):
        category = "missing"
    elif any(
        isinstance(item, TimeoutError) or "timeout" in type(item).__name__.lower()
        for item in chain
    ):
        category = "timeout"
    elif any(
        isinstance(item, ConnectionError)
        or "connection" in type(item).__name__.lower()
        for item in chain
    ):
        category = "connection"
    elif any(isinstance(item, OSError) for item in chain):
        category = "os_error"

    result: dict[str, object] = {
        "type": type(exc).__name__,
        "category": category,
    }
    cause_types = [type(item).__name__ for item in chain[1:]]
    if cause_types:
        result["causeTypes"] = cause_types
    for item in chain:
        if isinstance(item, OSError) and item.errno is not None:
            result["errno"] = item.errno
            break
    return result


def _maintenance_failure_detail(
    exc: Exception,
    *,
    data_root: Path,
) -> dict[str, object]:
    detail = _safe_error_summary(exc)
    if isinstance(exc, WorkDirectoryCleanupError):
        failed_work_directories = []
        for path, cause in zip(exc.failed_paths, exc.causes):
            try:
                identifier = str(path.relative_to(data_root))
            except ValueError:
                identifier = path.name
            failed_work_directories.append(
                {
                    "path": identifier,
                    "cause": _safe_error_summary(cause),
                }
            )
        detail.update(
            {
                "removed": exc.removed,
                "failedWorkDirectories": failed_work_directories,
            }
        )
        return detail
    if not isinstance(exc, ExpiredArtifactCleanupError):
        return detail
    job_record_failures = []
    for path, cause in zip(
        exc.failed_job_record_paths,
        exc.job_record_causes,
    ):
        try:
            identifier = str(path.relative_to(data_root))
        except ValueError:
            identifier = path.name
        job_record_failures.append(
            {
                "path": identifier,
                "cause": _safe_error_summary(cause),
            }
        )
    expiry_failures = []
    for job_id, cause in zip(
        exc.failed_expiry_job_ids,
        exc.expiry_causes,
    ):
        expiry_failures.append(
            {
                "jobId": job_id,
                "cause": _safe_error_summary(cause),
            }
        )
    legacy = []
    for path, cause in zip(exc.failed_legacy_paths, exc.legacy_causes):
        try:
            identifier = str(path.relative_to(data_root))
        except ValueError:
            identifier = path.name
        legacy.append(
            {
                "path": identifier,
                "cause": _safe_error_summary(cause),
            }
        )
    objects = []
    artifact_cleanup_failure = None
    if isinstance(exc.object_failure, ArtifactGarbageCollectionError):
        for key, cause in zip(
            exc.object_failure.failed_object_keys,
            exc.object_failure.causes,
        ):
            objects.append(
                {
                    "key": key,
                    "cause": _safe_error_summary(cause),
                }
            )
    elif exc.object_failure is not None:
        artifact_cleanup_failure = _safe_error_summary(exc.object_failure)
    detail.update(
        {
            "removed": exc.removed,
            "failedJobRecords": job_record_failures,
            "failedJobExpirations": expiry_failures,
            "failedLegacyPacks": legacy,
            "failedObjects": objects,
        }
    )
    if artifact_cleanup_failure is not None:
        detail["artifactCleanupFailure"] = artifact_cleanup_failure
    return detail


def _pipeline_producer_identity(
    repo_root: Path,
    worker_image_reference: str,
    *,
    required: bool,
) -> tuple[str | None, str | None]:
    """Load the fail-closed worker identity used by streams and pack reuse."""
    try:
        producer_image_digest = image_digest_from_reference(
            worker_image_reference
        )
        build_identity = verify_map_stream_build_identity(
            repo_root / "map-platform" / "config" / "map-stream-build-identity.json",
            repo_root,
        )
    except (OSError, ValueError):
        if required:
            raise
        return None, None
    return build_identity.producer_build_sha256, producer_image_digest


def _perform_maintenance(
    store: JobStore,
    data_root: Path,
    *,
    retention_days: int,
    artifact_store,
    max_gc_items: int,
    monitoring_store: MapMonitoringStore | None = None,
    monitoring_retention_days: int | None = None,
) -> dict[str, object]:
    result: dict[str, object] = {
        "maintenance": True,
        "expired": 0,
        "removedWorkDirs": 0,
        "removedRateLimits": 0,
    }
    failures: dict[str, object] = {}
    tasks = (
        (
            "expired",
            lambda: expire_ready_jobs(
                store,
                older_than_days=retention_days,
                artifact_store=artifact_store,
                max_gc_items=max_gc_items,
            ),
        ),
        (
            "removedWorkDirs",
            lambda: cleanup_work_dirs(data_root / "work", store),
        ),
        (
            "removedRateLimits",
            lambda: purge_expired_rate_limits(data_root / "rate-limits.sqlite3"),
        ),
    )
    if monitoring_store is not None:
        tasks += (
            (
                "monitoring",
                lambda: {
                    "synced": monitoring_store.sync_jobs(store.list()),
                    "removed": monitoring_store.prune(
                        older_than_days=monitoring_retention_days,
                    ),
                },
            ),
        )
    for field, task in tasks:
        try:
            result[field] = task()
        except Exception as exc:
            if field == "expired" and isinstance(
                exc,
                ExpiredArtifactCleanupError,
            ):
                result[field] = exc.expired_jobs
            elif field == "removedWorkDirs" and isinstance(
                exc,
                WorkDirectoryCleanupError,
            ):
                result[field] = exc.removed
            failures[field] = _maintenance_failure_detail(
                exc,
                data_root=data_root,
            )
    if failures:
        result["failures"] = failures
        raise MaintenanceIterationError(result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline map platform operations")
    parser.add_argument("--repo-root", default=os.environ.get("MAP_PLATFORM_REPO_ROOT", Path(__file__).resolve().parents[3]))
    parser.add_argument("--data-root", default=os.environ.get("MAP_PLATFORM_DATA_ROOT"))
    parser.add_argument("--source-index", default=os.environ.get("MAP_PLATFORM_SOURCE_INDEX"))
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_job = subparsers.add_parser("create-job")
    create_job.add_argument("--request-json", required=True, help="JSON map job request")

    get_job = subparsers.add_parser("get-job")
    get_job.add_argument("job_id")

    run = subparsers.add_parser("run-job")
    run.add_argument("job_id")

    monitoring_summary = subparsers.add_parser("monitoring-summary")
    monitoring_summary.add_argument("--window-hours", type=int, default=168)

    subparsers.add_parser("run-next")

    run_until_empty = subparsers.add_parser("run-until-empty")
    run_until_empty.add_argument("--max-jobs", type=int, default=None)

    worker_loop = subparsers.add_parser("worker-loop")
    worker_loop.add_argument("--idle-sleep-seconds", type=float, default=10.0)
    worker_loop.add_argument("--max-jobs", type=int, default=None)
    worker_loop.add_argument(
        "--heartbeat-path",
        default=os.environ.get(
            "MAP_PLATFORM_WORKER_HEARTBEAT_PATH",
            str(Path(os.environ.get("MAP_PLATFORM_DATA_ROOT", "/data")) / "health" / "worker"),
        ),
    )

    maintenance_loop = subparsers.add_parser("maintenance-loop")
    maintenance_loop.add_argument(
        "--retention-days",
        type=int,
        default=int(os.environ.get("MAP_PLATFORM_JOB_RETENTION_DAYS", "30")),
    )
    maintenance_loop.add_argument(
        "--maintenance-interval-seconds",
        type=float,
        default=float(os.environ.get("MAP_PLATFORM_MAINTENANCE_INTERVAL_SECONDS", "3600")),
    )
    maintenance_loop.add_argument(
        "--max-gc-items",
        type=int,
        default=int(os.environ.get("MAP_PLATFORM_MAINTENANCE_MAX_GC_ITEMS", "100")),
    )
    maintenance_loop.add_argument(
        "--heartbeat-path",
        default=os.environ.get(
            "MAP_PLATFORM_MAINTENANCE_HEARTBEAT_PATH",
            str(Path(os.environ.get("MAP_PLATFORM_DATA_ROOT", "/data")) / "health" / "maintenance"),
        ),
    )

    refresh_source = subparsers.add_parser("refresh-source")
    refresh_source.add_argument("region_id")
    refresh_source.add_argument("--force", action="store_true")

    expire = subparsers.add_parser("expire-ready")
    expire.add_argument("--older-than-days", type=int, default=30)

    subparsers.add_parser("cleanup-work")

    args = parser.parse_args()
    repo_root = Path(args.repo_root).resolve()
    data_root = (
        Path(args.data_root).resolve()
        if args.data_root
        else default_backend_data_root(repo_root)
    )
    source_index_path = (
        Path(args.source_index).resolve()
        if args.source_index
        else repo_root
        / "map-platform"
        / "backend"
        / "config"
        / "source-regions.json"
    )
    store = JobStore(data_root / "jobs")
    monitoring_retention_days = int(
        os.environ.get(
            "MAP_PLATFORM_MONITORING_RETENTION_DAYS",
            str(DEFAULT_MONITORING_RETENTION_DAYS),
        )
    )
    monitoring_store = MapMonitoringStore(
        data_root / "map-monitoring.sqlite3",
        retention_days=monitoring_retention_days,
    )
    source_provider = GeofabrikSourceProvider.from_environment(data_root)
    source_index = SourceIndex.from_json(
        source_index_path,
        fallback_provider=source_provider,
    )
    service = MapJobService(
        source_index,
        store,
        label_target2_enabled=label_target2_generation_enabled(),
        building_target3_enabled=building_target3_generation_enabled(),
        building_target3_allowlist=building_target3_generation_allowlist(),
    )
    source_cache = SourceCache(repo_root, data_root / "source-cache.json", data_root=data_root)

    def create_pipeline() -> MapBuildPipeline:
        map_signer = load_map_artifact_signer_from_environment()
        worker_image_reference = os.environ.get(
            "MAP_PLATFORM_WORKER_IMAGE_REFERENCE",
            "",
        ).strip()
        producer_build_sha256, producer_image_digest = (
            _pipeline_producer_identity(
                repo_root,
                worker_image_reference,
                required=map_signer is not None,
            )
        )
        return MapBuildPipeline(
            PipelinePaths(
                repo_root=repo_root,
                work_root=data_root / "work",
                pack_root=data_root / "packs",
            ),
            source_cache=source_cache,
            artifact_store=create_artifact_store_from_environment(data_root),
            map_signer=map_signer,
            producer_build_sha256=producer_build_sha256,
            producer_image_digest=producer_image_digest,
            source_preview_geometry_resolver=(
                source_provider.preview_geometry_for_source
                if source_provider is not None
                else None
            ),
        )

    if args.command == "create-job":
        request = json.loads(args.request_json)
        print(json.dumps(service.create_job(request).to_dict(), indent=2, sort_keys=True))
        return 0
    if args.command == "get-job":
        print(json.dumps(service.get_job(args.job_id).to_dict(), indent=2, sort_keys=True))
        return 0
    if args.command == "run-job":
        pipeline = create_pipeline()
        print(
            json.dumps(
                run_job(
                    store,
                    pipeline,
                    args.job_id,
                    monitoring_store=monitoring_store,
                ).to_dict(),
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if args.command == "monitoring-summary":
        monitoring_store.sync_jobs(store.list())
        print(
            json.dumps(
                monitoring_store.summary(window_hours=args.window_hours),
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if args.command == "run-next":
        pipeline = create_pipeline()
        result = MapWorker(
            store,
            pipeline,
            monitoring_store=monitoring_store,
        ).run_next()
        print(
            json.dumps(
                {
                    "workerId": result.worker_id,
                    "processed": result.processed,
                    "job": result.job.to_dict() if result.job else None,
                    "monitoring": result.monitoring_event,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if args.command == "run-until-empty":
        pipeline = create_pipeline()
        results = MapWorker(
            store,
            pipeline,
            monitoring_store=monitoring_store,
        ).run_until_empty(max_jobs=args.max_jobs)
        print(
            json.dumps(
                [
                    {
                        "workerId": result.worker_id,
                        "processed": result.processed,
                        "job": result.job.to_dict() if result.job else None,
                        "monitoring": result.monitoring_event,
                    }
                    for result in results
                ],
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if args.command == "worker-loop":
        pipeline = create_pipeline()
        heartbeat_path = Path(args.heartbeat_path)
        heartbeat_path.parent.mkdir(parents=True, exist_ok=True)

        def write_worker_heartbeat() -> None:
            heartbeat_path.write_text(str(time.time()))

        worker = MapWorker(
            store,
            pipeline,
            on_heartbeat=write_worker_heartbeat,
            monitoring_store=monitoring_store,
        )
        processed = 0
        while args.max_jobs is None or processed < args.max_jobs:
            write_worker_heartbeat()
            result = worker.run_next()
            write_worker_heartbeat()
            if result.processed:
                processed += 1
                event = dict(result.monitoring_event or {})
                event.setdefault("event", "map_job_processed")
                event["processed"] = True
                event.setdefault("workerId", result.worker_id)
                event.setdefault("jobId", result.job.job_id if result.job else None)
                print(json.dumps(event, sort_keys=True), flush=True)
                continue
            time.sleep(args.idle_sleep_seconds)
        return 0
    if args.command == "maintenance-loop":
        artifact_store = create_artifact_store_from_environment(data_root)
        heartbeat_path = Path(args.heartbeat_path)
        heartbeat_path.parent.mkdir(parents=True, exist_ok=True)
        while True:
            heartbeat_path.write_text(str(time.time()))
            try:
                maintenance_result = _perform_maintenance(
                    store,
                    data_root,
                    retention_days=args.retention_days,
                    artifact_store=artifact_store,
                    max_gc_items=args.max_gc_items,
                    monitoring_store=monitoring_store,
                    monitoring_retention_days=monitoring_retention_days,
                )
            except MaintenanceIterationError as exc:
                maintenance_result = exc.result
                heartbeat_path.write_text(str(time.time()))
                print(json.dumps(maintenance_result), flush=True)
                raise
            heartbeat_path.write_text(str(time.time()))
            print(
                json.dumps(maintenance_result),
                flush=True,
            )
            time.sleep(max(args.maintenance_interval_seconds, 1.0))
    if args.command == "refresh-source":
        matches = [region for region in source_index.all_regions(include_dynamic=True) if region.id == args.region_id]
        if not matches:
            raise SystemExit(f"unknown source region: {args.region_id}")
        cached = source_cache.ensure(matches[0], force=args.force)
        print(
            json.dumps(
                {
                    "regionId": cached.region_id,
                    "path": str(cached.path),
                    "bytes": cached.bytes,
                    "sha256": cached.sha256,
                    "cachedAt": cached.cached_at,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if args.command == "expire-ready":
        print(
            json.dumps(
                {
                    "expired": expire_ready_jobs(
                        store,
                        older_than_days=args.older_than_days,
                        artifact_store=create_artifact_store_from_environment(data_root),
                    )
                },
                indent=2,
            )
        )
        return 0
    if args.command == "cleanup-work":
        print(json.dumps({"removed": cleanup_work_dirs(data_root / "work", store)}, indent=2))
        return 0
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
