#!/usr/bin/env python3
"""Run and retain a pinned legacy-versus-selected target-3 benchmark suite."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cryptography.hazmat.primitives.asymmetric import ec

from map_platform.artifacts import FileSystemArtifactStore
from map_platform.building_benchmark import validate_benchmark_evidence
from map_platform.jobs import JobStore, MapJobService
from map_platform.map_signing import P256MapArtifactSigner
from map_platform.models import Bounds, SourceRegion
from map_platform.pipeline import MapBuildPipeline, PipelinePaths
from map_platform.source_cache import SourceCache
from map_platform.sources import SourceIndex


_SHA256 = re.compile(r"[0-9a-f]{64}")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_output(args: list[str]) -> str:
    return subprocess.run(
        args, check=True, text=True, capture_output=True
    ).stdout.strip()


def repository_identity(repo_root: Path) -> dict[str, str]:
    head = command_output(["git", "-C", str(repo_root), "rev-parse", "HEAD"])
    paths = command_output(
        [
            "git",
            "-C",
            str(repo_root),
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
        ]
    ).splitlines()
    digest = hashlib.sha256()
    for relative in sorted(paths):
        path = repo_root / relative
        if not path.is_file():
            continue
        encoded = relative.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        digest.update(path.stat().st_size.to_bytes(8, "big"))
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    return {"gitHead": head, "workspaceContentSha256": digest.hexdigest()}


def worker_identity(repo_root: Path) -> dict[str, str]:
    identity = {
        **repository_identity(repo_root),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "osmium": command_output(["osmium", "--version"]).splitlines()[0],
        "gdal": command_output(["ogr2ogr", "--version"]),
    }
    canonical = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    identity["workerFingerprintSha256"] = hashlib.sha256(canonical).hexdigest()
    return identity


def pbf_info(path: Path) -> dict[str, object]:
    document = json.loads(
        command_output(["osmium", "fileinfo", "-e", "-j", str(path)])
    )
    counts = document["data"]["count"]
    return {
        "bytes": path.stat().st_size,
        "bounds": document["data"]["bbox"],
        "objects": {
            key: int(counts[key]) for key in ("nodes", "ways", "relations")
        },
    }


def benchmark_request(fixture: dict[str, object]) -> dict[str, object]:
    request = dict(fixture["request"])
    request.update(
        {
            "displayName": "Shanghai selected-area 3D benchmark",
            "target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": 3,
                "firmwareVersion": "benchmark",
            },
            "labels": {
                "profileVersion": 1,
                "preferredLanguages": ["zh-Hans", "en"],
                "internationalFallback": "en-US",
            },
        }
    )
    return request


def require_source(source_pbf: Path, source_sha256: str) -> None:
    if not source_pbf.is_file():
        raise ValueError("benchmark source PBF is unavailable")
    if not _SHA256.fullmatch(source_sha256):
        raise ValueError("benchmark source SHA-256 is invalid")
    if file_sha256(source_pbf) != source_sha256:
        raise ValueError("benchmark source PBF does not match its pinned SHA-256")


def run_once(args: argparse.Namespace) -> None:
    repo_root = args.repo_root.resolve()
    source_pbf = args.source_pbf.resolve()
    require_source(source_pbf, args.source_sha256)
    source_info = pbf_info(source_pbf)
    fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
    run_root = args.run_root.resolve()
    run_root.mkdir(parents=True, exist_ok=True)
    source = SourceRegion(
        id="geofabrik-shanghai-benchmark",
        provider="geofabrik",
        name="Shanghai pinned benchmark",
        url=args.source_url,
        bounds=Bounds.from_list(source_info["bounds"]),
        local_path=str(source_pbf),
        published_at=args.source_published_at,
        checksum=args.source_sha256,
        license="ODbL-1.0",
    )
    store = JobStore(run_root / "jobs" / args.run_label)
    job = MapJobService(
        SourceIndex([source]),
        store,
        label_target2_enabled=True,
        building_target3_enabled=True,
    ).create_job(benchmark_request(fixture))
    job.worker_id = f"benchmark-{args.run_label}"
    job.attempts = 1
    worker = worker_identity(repo_root)
    signer = P256MapArtifactSigner(
        "selected-area-benchmark",
        ec.derive_private_key(7, ec.SECP256R1()),
    )
    pipeline = MapBuildPipeline(
        PipelinePaths(
            repo_root=repo_root,
            work_root=run_root / "work",
            pack_root=run_root / "packs",
        ),
        source_cache=SourceCache(
            repo_root,
            run_root / "source-cache.json",
            data_root=run_root / "data",
        ),
        artifact_store=FileSystemArtifactStore(run_root / "artifacts"),
        map_signer=signer,
        producer_build_sha256=worker["workspaceContentSha256"],
        producer_image_digest="sha256:" + worker["workerFingerprintSha256"],
        building_scope_mode=args.mode,
    )
    started = time.monotonic()
    first_preprocessing = None
    first_block = None

    def phase_progress(progress):
        nonlocal first_preprocessing, first_block
        elapsed = max(0, int(round((time.monotonic() - started) * 1_000)))
        if progress.get("phase") == "building_preprocessing" and first_preprocessing is None:
            first_preprocessing = elapsed
        if progress.get("phase") == "block_encoding" and first_block is None:
            first_block = elapsed

    result = pipeline.build(job, on_phase_progress=phase_progress)
    wall_milliseconds = max(0, int(round((time.monotonic() - started) * 1_000)))
    if first_preprocessing is None or first_block is None:
        raise RuntimeError("benchmark did not observe preprocessing and block progress")
    attempt_root = (
        run_root
        / "work"
        / job.job_id
        / re.sub(r"[^a-zA-Z0-9_-]", "-", job.worker_id)
    )
    query = pbf_info(attempt_root / "clipped.osm.pbf")
    with zipfile.ZipFile(result.legacy_archive_path) as archive:
        fmb_hashes = {
            name: hashlib.sha256(archive.read(name)).hexdigest()
            for name in sorted(archive.namelist())
            if name.endswith(".fmb")
        }
    record = {
        "mode": args.mode,
        "runLabel": args.run_label,
        "sourceIdentity": {
            "url": args.source_url,
            "publishedAt": args.source_published_at,
            "sha256": args.source_sha256,
            "bytes": source_info["bytes"],
        },
        "workerIdentity": worker,
        "sourceQueryBytes": query["bytes"],
        "sourceQueryObjects": query["objects"],
        "timings": {
            "wallMilliseconds": wall_milliseconds,
            "firstPreprocessingProgressMilliseconds": first_preprocessing,
            "firstBlockProgressMilliseconds": first_block,
        },
        "fmbSha256ByPath": fmb_hashes,
        "artifactMetrics": result.artifact_metrics,
        "artifacts": [artifact.to_dict() for artifact in result.artifacts],
    }
    args.output.write_text(
        json.dumps(record, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )


def parse_peak_resident_bytes(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    match = re.search(
        r"^\s*([0-9]+)\s+maximum resident set size\s*$", text, re.MULTILINE
    )
    if match is not None:
        return int(match.group(1))
    match = re.search(r"Maximum resident set size \(kbytes\):\s*([0-9]+)", text)
    if match is None:
        raise RuntimeError("benchmark time output has no peak RSS")
    return int(match.group(1)) * 1024


def suite(args: argparse.Namespace) -> None:
    require_source(args.source_pbf.resolve(), args.source_sha256)
    if args.workspace.exists():
        shutil.rmtree(args.workspace)
    args.workspace.mkdir(parents=True)
    run_specs = (
        ("legacyCold", "legacy", "legacy"),
        ("legacyWarm", "legacy", "legacy"),
        ("selectedCold", "selected", "selected"),
        ("selectedWarm", "selected", "selected"),
    )
    runs = {}
    environment = os.environ.copy()
    environment["PATH"] = os.pathsep.join(
        (str(Path(sys.executable).parent), environment.get("PATH", ""))
    )
    for label, mode, shared_root in run_specs:
        result_path = args.workspace / f"{label}.json"
        time_path = args.workspace / f"{label}.time.txt"
        command = [
            "/usr/bin/time",
            "-l",
            "-o",
            str(time_path),
            sys.executable,
            str(Path(__file__).resolve()),
            "_run",
            "--repo-root",
            str(args.repo_root),
            "--fixture",
            str(args.fixture),
            "--source-pbf",
            str(args.source_pbf),
            "--source-sha256",
            args.source_sha256,
            "--source-url",
            args.source_url,
            "--source-published-at",
            args.source_published_at,
            "--mode",
            mode,
            "--run-label",
            label,
            "--run-root",
            str(args.workspace / shared_root),
            "--output",
            str(result_path),
        ]
        subprocess.run(command, check=True, cwd=args.repo_root, env=environment)
        run = json.loads(result_path.read_text(encoding="utf-8"))
        run["peakResidentBytes"] = parse_peak_resident_bytes(time_path)
        runs[label] = run
    fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
    report = validate_benchmark_evidence(fixture, runs)
    args.output.write_text(
        json.dumps(report, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report["measurements"], sort_keys=True, indent=2))


def make_parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="command", required=True)
    suite_parser = subparsers.add_parser("suite")
    suite_parser.add_argument("--repo-root", type=Path, required=True)
    suite_parser.add_argument("--fixture", type=Path, required=True)
    suite_parser.add_argument("--source-pbf", type=Path, required=True)
    suite_parser.add_argument("--source-sha256", required=True)
    suite_parser.add_argument("--source-url", required=True)
    suite_parser.add_argument("--source-published-at", required=True)
    suite_parser.add_argument("--workspace", type=Path, required=True)
    suite_parser.add_argument("--output", type=Path, required=True)
    run_parser = subparsers.add_parser("_run")
    run_parser.add_argument("--repo-root", type=Path, required=True)
    run_parser.add_argument("--fixture", type=Path, required=True)
    run_parser.add_argument("--source-pbf", type=Path, required=True)
    run_parser.add_argument("--source-sha256", required=True)
    run_parser.add_argument("--source-url", required=True)
    run_parser.add_argument("--source-published-at", required=True)
    run_parser.add_argument("--mode", choices=("legacy", "selected"), required=True)
    run_parser.add_argument("--run-label", required=True)
    run_parser.add_argument("--run-root", type=Path, required=True)
    run_parser.add_argument("--output", type=Path, required=True)
    return result


def main() -> None:
    args = make_parser().parse_args()
    if args.command == "suite":
        suite(args)
    else:
        run_once(args)


if __name__ == "__main__":
    main()
