from __future__ import annotations

import argparse
import json
from pathlib import Path

from .jobs import JobStore, MapJobService
from .pipeline import MapBuildPipeline, PipelinePaths, run_job
from .sources import SourceIndex


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

    args = parser.parse_args()
    repo_root = Path(args.repo_root).resolve()
    data_root = Path(args.data_root).resolve() if args.data_root else repo_root / "backend" / "data"
    source_index_path = Path(args.source_index).resolve() if args.source_index else repo_root / "backend" / "config" / "source-regions.json"
    store = JobStore(data_root / "jobs")
    service = MapJobService(SourceIndex.from_json(source_index_path), store)

    if args.command == "create-job":
        request = json.loads(args.request_json)
        print(json.dumps(service.create_job(request).to_dict(), indent=2, sort_keys=True))
        return 0
    if args.command == "get-job":
        print(json.dumps(service.get_job(args.job_id).to_dict(), indent=2, sort_keys=True))
        return 0
    if args.command == "run-job":
        pipeline = MapBuildPipeline(
            PipelinePaths(repo_root=repo_root, work_root=data_root / "work", pack_root=data_root / "packs")
        )
        print(json.dumps(run_job(store, pipeline, args.job_id).to_dict(), indent=2, sort_keys=True))
        return 0
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())

