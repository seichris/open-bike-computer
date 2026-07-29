from __future__ import annotations

import json
import hashlib
import math
import re
import shutil
import subprocess
import time
import uuid
import zipfile
from copy import deepcopy
from contextlib import nullcontext
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable

from .artifacts import (
    BIKE_MAP_STREAM_FORMAT,
    BIKE_MAP_STREAM_MEDIA_TYPE,
    ZIP_MEDIA_TYPE,
    ZIP_STORED_FORMAT,
    ArtifactRecord,
    map_stream_object_key,
    sha256_file,
    zip_object_key,
)
from .manifest import (
    PipelineMetadata,
    build_manifest,
    stable_map_id,
    validate_pack_path,
    write_pack_archive,
)
from .map_stream import write_map_stream_artifact
from .models import JobStatus, MapJob, SourceRegion
from .reuse import (
    MapReuseKeys,
    SubsetReuseUnavailable,
    aligned_processing_bounds,
    block_from_pack_path,
    child_pack_path,
    required_blocks,
    reuse_keys,
)
from .source_cache import SourceCache
from .sources import SourceResolutionError


@dataclass(frozen=True)
class PipelinePaths:
    repo_root: Path
    work_root: Path
    pack_root: Path

    @property
    def osm_extract_root(self) -> Path:
        return self.repo_root / "tools" / "OSM_Extract"


@dataclass(frozen=True)
class MapBuildResult:
    map_id: str
    legacy_archive_path: Path
    artifacts: list[ArtifactRecord]
    artifact_metrics: dict[str, Any] | None = None

    def __iter__(self):
        yield self.map_id
        yield self.legacy_archive_path


class CommandRunner:
    def run(self, args: list[str], *, cwd: Path | None = None) -> str:
        result = subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True)
        return (result.stdout or result.stderr).strip()

    def run_streaming(self, args: list[str], *, cwd: Path | None = None, on_output=None) -> str:
        process = subprocess.Popen(
            args,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
        )
        output: list[str] = []
        try:
            assert process.stdout is not None
            for line in process.stdout:
                output.append(line)
                if on_output:
                    on_output(line)
            return_code = process.wait()
        except BaseException:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
        finally:
            if process.stdout is not None:
                process.stdout.close()
        combined_output = "".join(output)
        if return_code != 0:
            raise subprocess.CalledProcessError(return_code, args, output=combined_output)
        return combined_output.strip()


_MAP_PROGRESS_PATTERN = re.compile(r"MAP_PROGRESS:(\d+):(\d+)")


def parse_map_progress(line: str) -> tuple[int, int] | None:
    match = _MAP_PROGRESS_PATTERN.search(line)
    if match is None:
        return None
    completed, total = int(match.group(1)), int(match.group(2))
    if total <= 0 or completed < 0 or completed > total:
        return None
    return completed, total


class ProgressCoalescer:
    def __init__(self, *, min_interval_seconds: float = 2.0, min_fraction_delta: float = 0.01, clock=None):
        self.min_interval_seconds = min_interval_seconds
        self.min_fraction_delta = min_fraction_delta
        self.clock = clock or time.monotonic
        self.last_completed: int | None = None
        self.last_emitted_at: float | None = None

    def should_emit(self, completed: int, total: int) -> bool:
        now = self.clock()
        block_delta = max(1, math.ceil(total * self.min_fraction_delta))
        should_emit = (
            self.last_completed is None
            or completed >= total
            or completed - self.last_completed >= block_delta
            or self.last_emitted_at is None
            or now - self.last_emitted_at >= self.min_interval_seconds
        )
        if should_emit:
            self.last_completed = completed
            self.last_emitted_at = now
        return should_emit


class MapBuildPipeline:
    def __init__(
        self,
        paths: PipelinePaths,
        runner: CommandRunner | None = None,
        source_cache: SourceCache | None = None,
        *,
        artifact_store=None,
        map_signer=None,
        producer_build_sha256: str | None = None,
        producer_image_digest: str | None = None,
        source_preview_geometry_resolver: Callable[[SourceRegion], dict[str, Any] | None] | None = None,
    ):
        self.paths = paths
        self.runner = runner or CommandRunner()
        self.source_cache = source_cache or SourceCache(paths.repo_root)
        self.artifact_store = artifact_store
        self.map_signer = map_signer
        self.producer_build_sha256 = producer_build_sha256
        self.producer_image_digest = producer_image_digest
        self.source_preview_geometry_resolver = source_preview_geometry_resolver
        if self.map_signer is not None and self.artifact_store is None:
            raise ValueError("map stream generation requires durable artifact storage")
        if self.map_signer is not None and not re.fullmatch(
            r"[0-9a-f]{64}",
            self.producer_build_sha256 or "",
        ):
            raise ValueError("map stream generation requires an immutable build identity")
        if self.map_signer is not None and not re.fullmatch(
            r"sha256:[0-9a-f]{64}",
            self.producer_image_digest or "",
        ):
            raise ValueError("map stream generation requires an immutable worker image digest")

    def build(
        self,
        job: MapJob,
        on_status=None,
        on_progress=None,
        on_artifact_pending=None,
        artifact_publication_lease=None,
    ) -> MapBuildResult:
        map_id = stable_map_id(job)
        job.map_id = map_id
        attempt_id = re.sub(r"[^a-zA-Z0-9_-]", "-", job.worker_id or f"attempt-{job.attempts}")
        job_dir = self.paths.work_root / job.job_id / attempt_id
        clipped_pbf = job_dir / "clipped.osm.pbf"
        geojson_prefix = job_dir / "features"
        raw_output_dir = job_dir / "raw-map"
        pack_root = job_dir / "pack"
        vectmap_output = pack_root / "VECTMAP" / map_id
        archive_path = job_dir / f"{map_id}.zip"
        processing_bounds = aligned_processing_bounds(job)

        if job_dir.exists():
            shutil.rmtree(job_dir)
        job_dir.mkdir(parents=True)

        if on_status:
            on_status(JobStatus.RESOLVING_SOURCE)
        source_pbf = self._source_pbf_path(job)
        if on_status:
            on_status(JobStatus.EXTRACTING_PBF)
        self._extract_pbf(job, source_pbf, clipped_pbf, bounds=processing_bounds)
        if on_status:
            on_status(JobStatus.CONVERTING_FEATURES)
        self._convert_to_geojson(job, clipped_pbf, geojson_prefix, bounds=processing_bounds)
        self._extract_features(
            job,
            geojson_prefix,
            raw_output_dir,
            bounds=processing_bounds,
            on_progress=on_progress,
        )
        if on_status:
            on_status(JobStatus.PACKAGING)
        self._stage_vectmap(raw_output_dir, vectmap_output)

        return self._package_map(
            job,
            pack_root,
            archive_path,
            artifact_publication_lease=artifact_publication_lease,
            on_artifact_pending=on_artifact_pending,
        )

    def reuse_keys(self, job: MapJob) -> MapReuseKeys | None:
        if not re.fullmatch(r"[0-9a-f]{64}", self.producer_build_sha256 or ""):
            return None
        if not re.fullmatch(
            r"sha256:[0-9a-f]{64}",
            self.producer_image_digest or "",
        ):
            return None
        source_snapshot_sha256 = job.source_region.checksum
        if not re.fullmatch(r"[0-9a-f]{64}", source_snapshot_sha256 or ""):
            source_snapshot_sha256 = self.source_cache.ensure(
                job.source_region
            ).sha256
        return reuse_keys(
            job,
            producer_build_sha256=self.producer_build_sha256,
            producer_image_digest=self.producer_image_digest,
            source_snapshot_sha256=source_snapshot_sha256,
        )

    def build_subset(
        self,
        job: MapJob,
        parent: MapJob,
        *,
        on_status=None,
        on_progress=None,
        on_artifact_pending=None,
        artifact_publication_lease=None,
    ) -> MapBuildResult:
        map_id = stable_map_id(job)
        job.map_id = map_id
        attempt_id = re.sub(
            r"[^a-zA-Z0-9_-]",
            "-",
            job.worker_id or f"attempt-{job.attempts}",
        )
        job_dir = self.paths.work_root / job.job_id / attempt_id
        pack_root = job_dir / "pack"
        archive_path = job_dir / f"{map_id}.zip"
        if job_dir.exists():
            shutil.rmtree(job_dir)
        job_dir.mkdir(parents=True)
        if on_status:
            on_status(JobStatus.PACKAGING)
        self._stage_subset_pack(job, parent, pack_root)
        if on_progress:
            on_progress(1, 1)
        return self._package_map(
            job,
            pack_root,
            archive_path,
            artifact_publication_lease=artifact_publication_lease,
            on_artifact_pending=on_artifact_pending,
        )

    def _package_map(
        self,
        job: MapJob,
        pack_root: Path,
        archive_path: Path,
        *,
        artifact_publication_lease=None,
        on_artifact_pending=None,
    ) -> MapBuildResult:
        map_id = job.map_id or stable_map_id(job)
        job.map_id = map_id
        job_dir = archive_path.parent
        self._resolve_source_preview_geometry(job)
        manifest = build_manifest(job, pack_root, self._pipeline_metadata())
        write_pack_archive(pack_root, manifest, archive_path)
        artifacts: list[ArtifactRecord] = []
        metrics: dict[str, Any] = {}
        if self.artifact_store is not None:
            hashing_started = time.perf_counter()
            zip_sha256 = sha256_file(archive_path)
            metrics["zipHashingSeconds"] = time.perf_counter() - hashing_started
            zip_key = zip_object_key(map_id, zip_sha256)
            lease = (
                artifact_publication_lease(zip_key)
                if artifact_publication_lease
                else nullcontext()
            )
            with lease:
                if on_artifact_pending:
                    on_artifact_pending(zip_key)
                storage_started = time.perf_counter()
                self.artifact_store.put(
                    archive_path,
                    zip_key,
                    sha256=zip_sha256,
                    media_type=ZIP_MEDIA_TYPE,
                )
            metrics["zipStorageSeconds"] = time.perf_counter() - storage_started
            artifacts.append(
                ArtifactRecord(
                    format=ZIP_STORED_FORMAT,
                    media_type=ZIP_MEDIA_TYPE,
                    filename=archive_path.name,
                    object_key=zip_key,
                    bytes=archive_path.stat().st_size,
                    sha256=zip_sha256,
                )
            )

        if self.map_signer is not None:
            stream_path = job_dir / f"{map_id}.bmap"
            stream_manifest = deepcopy(manifest)
            stream_manifest["producer"] = {
                "buildSha256": self.producer_build_sha256,
                "imageDigest": self.producer_image_digest,
            }
            stream_build = write_map_stream_artifact(
                pack_root,
                stream_manifest,
                self.map_signer,
                stream_path,
            )
            stream_key = map_stream_object_key(
                map_id,
                stream_build.signed_manifest_receipt,
                stream_build.signature_key_id,
                self.map_signer.public_key_sha256,
                self.producer_build_sha256,
                self.producer_image_digest,
            )
            lease = (
                artifact_publication_lease(stream_key)
                if artifact_publication_lease
                else nullcontext()
            )
            with lease:
                if on_artifact_pending:
                    on_artifact_pending(stream_key)
                storage_started = time.perf_counter()
                self.artifact_store.put(
                    stream_path,
                    stream_key,
                    sha256=stream_build.sha256,
                    media_type=BIKE_MAP_STREAM_MEDIA_TYPE,
                )
            metrics["streamStorageSeconds"] = time.perf_counter() - storage_started
            metrics.update(
                {f"stream{name[0].upper()}{name[1:]}": value for name, value in stream_build.timings.items()}
            )
            metrics.update(
                {
                    "streamFileCount": stream_build.file_count,
                    "streamPayloadBytes": stream_build.payload_bytes,
                    "streamArtifactBytes": stream_build.bytes,
                    "streamSignatureKeyId": stream_build.signature_key_id,
                }
            )
            artifacts.insert(
                0,
                ArtifactRecord(
                    format=BIKE_MAP_STREAM_FORMAT,
                    media_type=BIKE_MAP_STREAM_MEDIA_TYPE,
                    filename=stream_path.name,
                    object_key=stream_key,
                    bytes=stream_build.bytes,
                    sha256=stream_build.sha256,
                    manifest_receipt=stream_build.manifest_receipt,
                    signed_manifest_receipt=stream_build.signed_manifest_receipt,
                    signature_key_id=stream_build.signature_key_id,
                    signature_key_sha256=self.map_signer.public_key_sha256,
                    producer_build_sha256=self.producer_build_sha256,
                    producer_image_digest=self.producer_image_digest,
                ),
            )
        return MapBuildResult(
            map_id=map_id,
            legacy_archive_path=archive_path,
            artifacts=artifacts,
            artifact_metrics=metrics or None,
        )

    def published_archive_path(self, map_id: str, job_id: str) -> Path:
        return self.paths.pack_root / map_id / f"{job_id}.zip"

    def _resolve_source_preview_geometry(self, job: MapJob) -> None:
        resolver = self.source_preview_geometry_resolver
        if job.source_region.preview_geometry is not None or resolver is None:
            return
        try:
            geometry = resolver(job.source_region)
        except SourceResolutionError:
            return
        if isinstance(geometry, dict) and geometry:
            job.source_region = replace(
                job.source_region,
                preview_geometry=geometry,
            )

    def _source_pbf_path(self, job: MapJob) -> Path:
        return self.source_cache.ensure(job.source_region).path

    def _extract_pbf(
        self,
        job: MapJob,
        source_pbf: Path,
        clipped_pbf: Path,
        *,
        bounds=None,
    ) -> None:
        bounds = bounds or job.geometry.bounds
        args = [
            "osmium",
            "extract",
            "--strategy=smart",
            "-b",
            f"{bounds.min_lon},{bounds.min_lat},{bounds.max_lon},{bounds.max_lat}",
            str(source_pbf),
            "-o",
            str(clipped_pbf),
            "--overwrite",
        ]
        if job.geometry.geometry and job.geometry.mode.value == "custom_polygon":
            polygon_path = clipped_pbf.parent / "clip.geojson"
            polygon_path.write_text(json.dumps(job.geometry.geometry))
            args = [
                "osmium",
                "extract",
                "--strategy=smart",
                "-p",
                str(polygon_path),
                str(source_pbf),
                "-o",
                str(clipped_pbf),
                "--overwrite",
            ]
        self.runner.run(args)

    def _convert_to_geojson(
        self,
        job: MapJob,
        clipped_pbf: Path,
        geojson_prefix: Path,
        *,
        bounds=None,
    ) -> None:
        bounds = bounds or job.geometry.bounds
        script = self.paths.osm_extract_root / "scripts" / "pbf_to_geojson.sh"
        self.runner.run(
            [
                "bash",
                str(script),
                str(bounds.min_lon),
                str(bounds.min_lat),
                str(bounds.max_lon),
                str(bounds.max_lat),
                str(clipped_pbf),
                str(geojson_prefix),
            ],
            cwd=self.paths.osm_extract_root / "scripts",
        )

    def _extract_features(
        self,
        job: MapJob,
        geojson_prefix: Path,
        raw_output_dir: Path,
        *,
        bounds=None,
        on_progress=None,
    ) -> None:
        bounds = bounds or job.geometry.bounds
        script = self.paths.osm_extract_root / "scripts" / "extract_features.py"
        args = [
            "python",
            str(script),
            str(bounds.min_lon),
            str(bounds.min_lat),
            str(bounds.max_lon),
            str(bounds.max_lat),
            str(geojson_prefix),
            str(raw_output_dir),
        ]
        progress_coalescer = ProgressCoalescer()

        def handle_output(line: str) -> None:
            progress = parse_map_progress(line)
            if progress is not None and on_progress and progress_coalescer.should_emit(*progress):
                on_progress(*progress)

        if on_progress and hasattr(self.runner, "run_streaming"):
            self.runner.run_streaming(
                args,
                cwd=self.paths.osm_extract_root / "scripts",
                on_output=handle_output,
            )
            return

        output = self.runner.run(args, cwd=self.paths.osm_extract_root / "scripts")
        if on_progress:
            for line in output.splitlines():
                handle_output(line)

    def _stage_subset_pack(
        self,
        child: MapJob,
        parent: MapJob,
        pack_root: Path,
    ) -> None:
        if not parent.pack_path or not parent.map_id:
            raise SubsetReuseUnavailable("parent map pack is unavailable")
        parent_archive = Path(parent.pack_path)
        if not parent_archive.is_file():
            raise SubsetReuseUnavailable("parent map pack is missing")
        parent_zip_artifact = next(
            (
                artifact
                for artifact in parent.artifacts
                if artifact.format == ZIP_STORED_FORMAT
            ),
            None,
        )
        if parent_zip_artifact is None:
            raise SubsetReuseUnavailable("parent map pack has no immutable ZIP identity")
        try:
            parent_identity_matches = (
                parent_archive.stat().st_size == parent_zip_artifact.bytes
                and sha256_file(parent_archive) == parent_zip_artifact.sha256
            )
        except OSError as exc:
            raise SubsetReuseUnavailable("parent map pack cannot be read") from exc
        if not parent_identity_matches:
            raise SubsetReuseUnavailable("parent map pack identity is invalid")
        required = required_blocks(child.geometry.bounds)
        child_map_id = child.map_id or stable_map_id(child)
        copied_fmb = 0
        copied_paths: set[str] = set()

        try:
            with zipfile.ZipFile(parent_archive, "r") as archive:
                infos = archive.infolist()
                names = [info.filename for info in infos]
                if len(names) != len(set(names)):
                    raise SubsetReuseUnavailable("parent map pack has duplicate entries")
                try:
                    manifest_info = archive.getinfo("manifest.json")
                except KeyError as exc:
                    raise SubsetReuseUnavailable("parent map manifest is missing") from exc
                if manifest_info.file_size > 16 * 1024 * 1024:
                    raise SubsetReuseUnavailable("parent map manifest is too large")
                manifest = json.loads(archive.read(manifest_info))
                if not isinstance(manifest, dict) or manifest.get("mapId") != parent.map_id:
                    raise SubsetReuseUnavailable("parent map manifest identity is invalid")
                if manifest.get("bounds") != parent.geometry.bounds.to_list():
                    raise SubsetReuseUnavailable("parent map manifest bounds are invalid")
                files = manifest.get("files")
                if not isinstance(files, list) or not files:
                    raise SubsetReuseUnavailable("parent map manifest has no files")

                manifest_paths: set[str] = set()
                for entry in files:
                    if not isinstance(entry, dict):
                        raise SubsetReuseUnavailable("parent map manifest file is invalid")
                    path = entry.get("path")
                    byte_count = entry.get("bytes")
                    expected_sha256 = entry.get("sha256")
                    if (
                        not isinstance(path, str)
                        or isinstance(byte_count, bool)
                        or not isinstance(byte_count, int)
                        or byte_count < 0
                        or not isinstance(expected_sha256, str)
                        or not re.fullmatch(r"[0-9a-f]{64}", expected_sha256)
                    ):
                        raise SubsetReuseUnavailable("parent map manifest file is invalid")
                    try:
                        validate_pack_path(path)
                    except ValueError as exc:
                        raise SubsetReuseUnavailable(str(exc)) from exc
                    if path in manifest_paths:
                        raise SubsetReuseUnavailable("parent map manifest has duplicate files")
                    manifest_paths.add(path)
                    parts = path.split("/")
                    if len(parts) != 4 or parts[1] != parent.map_id:
                        raise SubsetReuseUnavailable("parent map file identity is invalid")
                    block = block_from_pack_path(path)
                    if block not in required:
                        continue
                    try:
                        info = archive.getinfo(path)
                    except KeyError as exc:
                        raise SubsetReuseUnavailable("parent map file is missing") from exc
                    if (
                        info.is_dir()
                        or info.flag_bits & 0x1
                        or info.compress_type != zipfile.ZIP_STORED
                        or info.file_size != byte_count
                    ):
                        raise SubsetReuseUnavailable("parent map file metadata is invalid")
                    extension = Path(path).suffix.removeprefix(".")
                    destination_relative = child_pack_path(child_map_id, block, extension)
                    if destination_relative in copied_paths:
                        raise SubsetReuseUnavailable("parent block selection is ambiguous")
                    copied_paths.add(destination_relative)
                    destination = pack_root / destination_relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    digest = hashlib.sha256()
                    copied = 0
                    with archive.open(info, "r") as source, destination.open("xb") as output:
                        for chunk in iter(lambda: source.read(1024 * 1024), b""):
                            output.write(chunk)
                            digest.update(chunk)
                            copied += len(chunk)
                    if copied != byte_count or digest.hexdigest() != expected_sha256:
                        destination.unlink(missing_ok=True)
                        raise SubsetReuseUnavailable("parent map block hash is invalid")
                    if extension == "fmb":
                        copied_fmb += 1
        except SubsetReuseUnavailable:
            raise
        except (OSError, ValueError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
            raise SubsetReuseUnavailable(f"parent map pack is invalid: {exc}") from exc

        if copied_fmb == 0:
            raise SubsetReuseUnavailable("parent map contains no required binary blocks")

    def _stage_vectmap(self, raw_output_dir: Path, vectmap_output: Path) -> None:
        if not raw_output_dir.exists():
            raise FileNotFoundError(f"OSM_Extract output is missing: {raw_output_dir}")
        vectmap_output.mkdir(parents=True, exist_ok=True)
        for child in raw_output_dir.iterdir():
            destination = vectmap_output / child.name
            if child.is_dir():
                shutil.copytree(child, destination)
            elif child.suffix in {".fmb", ".fmp"}:
                shutil.copy2(child, destination)

    def _pipeline_metadata(self) -> PipelineMetadata:
        osmium_version = "unknown"
        try:
            osmium_version = self.runner.run(["osmium", "--version"]).splitlines()[0]
        except Exception:
            pass
        return PipelineMetadata(osmium_version=osmium_version)


def run_job(store, pipeline: MapBuildPipeline, job_id: str, *, heartbeat_interval_seconds: float = 30.0) -> MapJob:
    worker_id = f"api-{uuid.uuid4().hex[:8]}"
    job = store.claim(job_id, worker_id)

    def update(status: JobStatus) -> None:
        store.update_status_unless_cancelled(job_id, status, worker_id=worker_id)

    def update_progress(completed: int, total: int) -> None:
        store.update_progress_unless_cancelled(job_id, completed, total, worker_id=worker_id)

    try:
        with store.keep_worker_lease_alive(
            job_id,
            worker_id=worker_id,
            interval_seconds=heartbeat_interval_seconds,
        ):
            build_kwargs = {
                "on_status": update,
                "on_progress": update_progress,
            }
            if isinstance(pipeline, MapBuildPipeline):
                build_kwargs["artifact_publication_lease"] = lambda object_key: (
                    store.artifact_publication_lease(
                        job_id,
                        object_key,
                        worker_id=worker_id,
                    )
                )
            reuse_identity = (
                pipeline.reuse_keys(job)
                if isinstance(pipeline, MapBuildPipeline)
                else None
            )
            reuse_strategy = None
            reuse_source_job_id = None
            if reuse_identity is not None:
                store.set_build_keys_unless_cancelled(
                    job_id,
                    worker_id=worker_id,
                    build_cache_key=reuse_identity.exact,
                    build_compatibility_key=reuse_identity.compatibility,
                )
                exact = store.find_exact_reuse_candidate(
                    job_id=job_id,
                    build_cache_key=reuse_identity.exact,
                )
                if exact is not None:
                    reused = store.complete_exact_reuse(
                        job_id,
                        worker_id=worker_id,
                        source_job_id=exact.job_id,
                        build_cache_key=reuse_identity.exact,
                        build_compatibility_key=reuse_identity.compatibility,
                    )
                    if reused is not None:
                        return reused
                build_result = None
                for parent in store.find_subset_reuse_candidates(
                    job,
                    build_compatibility_key=reuse_identity.compatibility,
                ):
                    try:
                        build_result = pipeline.build_subset(
                            job,
                            parent,
                            **build_kwargs,
                        )
                    except SubsetReuseUnavailable:
                        continue
                    reuse_strategy = "subset"
                    reuse_source_job_id = parent.job_id
                    break
                if build_result is None:
                    build_result = pipeline.build(job, **build_kwargs)
            else:
                build_result = pipeline.build(job, **build_kwargs)
            map_id, archive_path = build_result
        published_archive = (
            pipeline.published_archive_path(map_id, job.job_id)
            if hasattr(pipeline, "published_archive_path")
            else archive_path
        )
        return store.complete_job(
            job_id,
            worker_id=worker_id,
            map_id=map_id,
            built_archive=archive_path,
            published_archive=published_archive,
            artifacts=getattr(build_result, "artifacts", None),
            artifact_metrics=getattr(build_result, "artifact_metrics", None),
            build_cache_key=(reuse_identity.exact if reuse_identity else None),
            build_compatibility_key=(
                reuse_identity.compatibility if reuse_identity else None
            ),
            reuse_strategy=reuse_strategy,
            reuse_source_job_id=reuse_source_job_id,
        )
    except Exception as exc:
        current = store.get(job_id)
        if current.status == JobStatus.CANCELLED or current.worker_id != worker_id:
            if (
                current.status == JobStatus.CANCELLED
                and isinstance(pipeline, MapBuildPipeline)
                and pipeline.artifact_store is not None
            ):
                store.queue_terminal_pending_artifacts(job_id)
                current = store.get(job_id)
            return current
        failed = store.update_status_unless_cancelled(
            job_id,
            JobStatus.FAILED,
            error=str(exc),
            error_code=getattr(exc, "code", "map_build_failed"),
            worker_id=worker_id,
        )
        if isinstance(pipeline, MapBuildPipeline) and pipeline.artifact_store is not None:
            store.queue_terminal_pending_artifacts(job_id)
            failed = store.get(job_id)
        return failed
