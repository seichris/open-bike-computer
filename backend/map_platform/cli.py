from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from .jobs import JobStore, MapJobService
from .pipeline import MapBuildPipeline, PipelinePaths, run_job
from .source_cache import SourceCache
from .sources import SourceIndex
from .worker import MapWorker, cleanup_work_dirs, expire_ready_jobs


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline map platform operations")
    parser.add_argument("--repo-root", default=Path(__file__).resolve().parents[2])
    parser.add_argument("--data-root", default=None)
    parser.add_argument("--source-index", default=None)
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_job = subparsers.add_parser("create-job")
    create_job.add_argument("--request-json", required=True, help="JSON map job request")

    get_job = subparsers.add_parser("get-job")
    get_job.add_argument("job_id")

    run = subparsers.add_parser("run-job")
    run.add_argument("job_id")

    subparsers.add_parser("run-next")

    run_until_empty = subparsers.add_parser("run-until-empty")
    run_until_empty.add_argument("--max-jobs", type=int, default=None)

    worker_loop = subparsers.add_parser("worker-loop")
    worker_loop.add_argument("--idle-sleep-seconds", type=float, default=10.0)
    worker_loop.add_argument("--max-jobs", type=int, default=None)

    refresh_source = subparsers.add_parser("refresh-source")
    refresh_source.add_argument("region_id")
    refresh_source.add_argument("--force", action="store_true")

    expire = subparsers.add_parser("expire-ready")
    expire.add_argument("--older-than-days", type=int, default=30)

    subparsers.add_parser("cleanup-work")

    args = parser.parse_args()
    repo_root = Path(args.repo_root).resolve()
    data_root = Path(args.data_root).resolve() if args.data_root else repo_root / "backend" / "data"
    source_index_path = Path(args.source_index).resolve() if args.source_index else repo_root / "backend" / "config" / "source-regions.json"
    store = JobStore(data_root / "jobs")
    source_index = SourceIndex.from_json(source_index_path)
    service = MapJobService(source_index, store)
    source_cache = SourceCache(repo_root, data_root / "source-cache.json", data_root=data_root)

    if args.command == "create-job":
        request = json.loads(args.request_json)
        print(json.dumps(service.create_job(request).to_dict(), indent=2, sort_keys=True))
        return 0
    if args.command == "get-job":
        print(json.dumps(service.get_job(args.job_id).to_dict(), indent=2, sort_keys=True))
        return 0
    if args.command == "run-job":
        pipeline = MapBuildPipeline(
            PipelinePaths(repo_root=repo_root, work_root=data_root / "work", pack_root=data_root / "packs"),
            source_cache=source_cache,
        )
        print(json.dumps(run_job(store, pipeline, args.job_id).to_dict(), indent=2, sort_keys=True))
        return 0
    if args.command == "run-next":
        pipeline = MapBuildPipeline(
            PipelinePaths(repo_root=repo_root, work_root=data_root / "work", pack_root=data_root / "packs"),
            source_cache=source_cache,
        )
        result = MapWorker(store, pipeline).run_next()
        print(
            json.dumps(
                {
                    "workerId": result.worker_id,
                    "processed": result.processed,
                    "job": result.job.to_dict() if result.job else None,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if args.command == "run-until-empty":
        pipeline = MapBuildPipeline(
            PipelinePaths(repo_root=repo_root, work_root=data_root / "work", pack_root=data_root / "packs"),
            source_cache=source_cache,
        )
        results = MapWorker(store, pipeline).run_until_empty(max_jobs=args.max_jobs)
        print(
            json.dumps(
                [
                    {
                        "workerId": result.worker_id,
                        "processed": result.processed,
                        "job": result.job.to_dict() if result.job else None,
                    }
                    for result in results
                ],
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if args.command == "worker-loop":
        pipeline = MapBuildPipeline(
            PipelinePaths(repo_root=repo_root, work_root=data_root / "work", pack_root=data_root / "packs"),
            source_cache=source_cache,
        )
        worker = MapWorker(store, pipeline)
        processed = 0
        while args.max_jobs is None or processed < args.max_jobs:
            result = worker.run_next()
            if result.processed:
                processed += 1
                print(
                    json.dumps({"workerId": result.worker_id, "processed": True, "jobId": result.job.job_id if result.job else None}),
                    flush=True,
                )
                continue
            time.sleep(args.idle_sleep_seconds)
        return 0
    if args.command == "refresh-source":
        matches = [region for region in source_index.regions if region.id == args.region_id]
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
        print(json.dumps({"expired": expire_ready_jobs(store, older_than_days=args.older_than_days)}, indent=2))
        return 0
    if args.command == "cleanup-work":
        print(json.dumps({"removed": cleanup_work_dirs(data_root / "work", store)}, indent=2))
        return 0
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
