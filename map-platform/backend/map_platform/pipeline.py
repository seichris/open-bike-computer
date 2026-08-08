from __future__ import annotations

import base64
import json
import hashlib
import math
import os
import re
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
from copy import deepcopy
from contextlib import contextmanager, nullcontext
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
    build_identity_manifest,
    build_manifest,
    stable_map_id,
    validate_pack_path,
    write_pack_archive,
)
from .map_stream import (
    FIXED_HEADER_BYTES,
    MAX_KEY_ID_BYTES,
    MAX_MANIFEST_BYTES,
    RAW_P256_SIGNATURE_BYTES,
    MapStreamHeader,
    MapStreamSignatureEnvelope,
    canonical_stream_manifest_bytes,
    manifest_receipt,
    signed_manifest_receipt,
    write_map_stream_artifact,
)
from .map_labels import LABEL_RENDERER_FORMAT_VERSION, renderer_format_version
from .map_buildings import (
    BUILDING_RENDERER_FORMAT_VERSION,
    load_building_calibration_window,
)
from .building_scope import (
    BuildingScopeError,
    ScopePlan,
    legacy_building_scope_diagnostics,
    plan_building_scope,
    x_to_lon,
    y_to_lat,
)
from .building_identity import (
    calibration_generation_from_manifest,
    calibration_generation_manifest_path,
    canonical_json as canonical_building_json,
    selected_calibration_identity,
    selected_building_identity,
)
from .models import JobStatus, MapJob, SourceRegion
from .monitoring import MapMonitoringStore
from .preview import render_boundary_preview
from .reuse import (
    MapReuseKeys,
    SubsetReuseUnavailable,
    aligned_processing_bounds,
    block_from_pack_path,
    child_pack_path,
    required_blocks,
    reuse_keys,
    expanded_building_source_bounds,
)
from .source_cache import SourceCache, SourceCacheError
from .sources import SourceResolutionError


@dataclass(frozen=True)
class PipelinePaths:
    repo_root: Path
    work_root: Path
    pack_root: Path

    @property
    def osm_extract_root(self) -> Path:
        return self.repo_root / "tools" / "OSM_Extract"

    @property
    def building_cache_root(self) -> Path:
        return self.work_root.parent / "building-cache"


@dataclass(frozen=True)
class MapBuildResult:
    map_id: str
    legacy_archive_path: Path
    artifacts: list[ArtifactRecord]
    artifact_metrics: dict[str, Any] | None = None
    build_cache_key: str | None = None
    build_cache_aliases: list[str] | None = None
    build_identity_derivation: dict[str, Any] | None = None
    build_compatibility_key: str | None = None

    def __iter__(self):
        yield self.map_id
        yield self.legacy_archive_path


class CommandRunner:
    def run(
        self,
        args: list[str],
        *,
        cwd: Path | None = None,
        cancellation_check=None,
    ) -> str:
        if cancellation_check is not None:
            return self.run_streaming(
                args,
                cwd=cwd,
                cancellation_check=cancellation_check,
            )
        result = subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True)
        return (result.stdout or result.stderr).strip()

    def run_streaming(
        self,
        args: list[str],
        *,
        cwd: Path | None = None,
        on_output=None,
        cancellation_check=None,
    ) -> str:
        process = subprocess.Popen(
            args,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
            start_new_session=True,
        )
        output: list[str] = []
        pending = ""
        stdout_open = True
        try:
            assert process.stdout is not None
            descriptor = process.stdout.fileno()
            while True:
                if cancellation_check is not None and cancellation_check():
                    raise RuntimeError("preprocessing command was cancelled")
                if not stdout_open:
                    if process.poll() is not None:
                        break
                    time.sleep(0.1)
                    continue
                readable, _, _ = select.select([descriptor], [], [], 0.1)
                if readable:
                    chunk = os.read(descriptor, 64 * 1024)
                    if not chunk:
                        stdout_open = False
                        continue
                    pending += chunk.decode("utf-8", errors="replace")
                    while "\n" in pending:
                        line, pending = pending.split("\n", 1)
                        line += "\n"
                        output.append(line)
                        if on_output:
                            on_output(line)
                elif process.poll() is not None:
                    chunk = os.read(descriptor, 64 * 1024)
                    if chunk:
                        pending += chunk.decode("utf-8", errors="replace")
                        continue
                    stdout_open = False
            if pending:
                output.append(pending)
                if on_output:
                    on_output(pending)
            return_code = process.wait()
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
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
_LABEL_STATS_PREFIX = "LABEL_STATS:"
_BUILDING_STATS_PREFIX = "BUILDING_STATS:"
_BUILDING_SCOPE_PREFIX = "BUILDING_SCOPE:"
_BUILDING_FAILURE_PREFIX = "BUILDING_PREPROCESS_FAILURE:"
_BUILDING_PREPROCESS_PROGRESS_PREFIX = "BUILDING_PREPROCESS_PROGRESS:"
_BUILDING_FAILURE_CODES = {
    "building_scope_exceeded",
    "building_relation_incomplete",
    "building_calibration_unavailable",
    "building_source_snapshot_changed",
    "building_scope_policy_invalid",
}
_BUILDING_FAILURE_MESSAGES = {
    "building_scope_exceeded": "selected building scope exceeds policy",
    "building_relation_incomplete": "selected building relation closure is incomplete",
    "building_calibration_unavailable": "selected building calibration is unavailable",
    "building_source_snapshot_changed": "selected building source snapshot changed",
    "building_scope_policy_invalid": "selected building scope policy is invalid",
}


def parse_map_progress(line: str) -> tuple[int, int] | None:
    match = _MAP_PROGRESS_PATTERN.search(line)
    if match is None:
        return None
    completed, total = int(match.group(1)), int(match.group(2))
    if total <= 0 or completed < 0 or completed > total:
        return None
    return completed, total


def parse_label_stats(line: str) -> dict[str, Any] | None:
    return _parse_structured_stats(line, _LABEL_STATS_PREFIX)


def parse_building_stats(line: str) -> dict[str, Any] | None:
    return _parse_structured_stats(line, _BUILDING_STATS_PREFIX)


def parse_building_scope(line: str) -> dict[str, Any] | None:
    return _parse_structured_stats(line, _BUILDING_SCOPE_PREFIX)


def parse_building_failure(output: str) -> dict[str, str] | None:
    for line in output.splitlines():
        marker = line.find(_BUILDING_FAILURE_PREFIX)
        if marker < 0:
            continue
        payload = line[marker + len(_BUILDING_FAILURE_PREFIX):].strip()
        if not payload or len(payload) > 16 * 1024:
            continue
        try:
            value = json.loads(payload)
        except (TypeError, ValueError):
            continue
        if (
            isinstance(value, dict)
            and value.get("code") in _BUILDING_FAILURE_CODES
            and isinstance(value.get("message"), str)
            and 0 < len(value["message"]) <= 1_024
        ):
            return {"code": value["code"], "message": value["message"]}
    return None


def parse_building_preprocess_progress(line: str) -> dict[str, Any] | None:
    value = _parse_structured_stats(line, _BUILDING_PREPROCESS_PROGRESS_PREFIX)
    if not isinstance(value, dict):
        return None
    unit = value.get("unit") or value.get("phase")
    completed = value.get("completed")
    total = value.get("total")
    indeterminate = value.get("indeterminate", False)
    if (
        not isinstance(unit, str)
        or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", unit)
        or not isinstance(indeterminate, bool)
        or isinstance(completed, bool)
        or not isinstance(completed, int)
        or completed < 0
    ):
        return None
    if total is None:
        if not indeterminate:
            return None
    elif (
        isinstance(total, bool)
        or not isinstance(total, int)
        or total <= 0
        or completed > total
    ):
        return None
    return {
        "unit": unit,
        "completed": completed if total is not None else None,
        "total": total,
        "indeterminate": indeterminate,
    }


def safe_build_failure(job: MapJob, exc: Exception) -> tuple[str, str]:
    code = getattr(exc, "code", "map_build_failed")
    if isinstance(exc, SourceCacheError):
        return (
            "map source cache is unavailable; "
            f"jobId={job.job_id}; sourceRegionId={job.source_region.id}",
            "source_cache_unavailable",
        )
    if code not in _BUILDING_FAILURE_MESSAGES:
        return str(exc), code
    identifiers = [f"jobId={job.job_id}"]
    frozen = job.building_preprocessing_inputs
    if isinstance(frozen, dict):
        scope_sha256 = frozen.get("scopePlan", {}).get("scopePlanSha256")
        calibration_key = frozen.get("calibrationGeneration", {}).get(
            "calibrationKey"
        )
        source_sha256 = frozen.get("sourceSnapshotSha256")
        if isinstance(scope_sha256, str):
            identifiers.append(f"scopePlanSha256={scope_sha256}")
        if isinstance(calibration_key, str):
            identifiers.append(f"calibrationKey={calibration_key}")
        if isinstance(source_sha256, str):
            identifiers.append(f"sourceSnapshotSha256={source_sha256}")
    return f"{_BUILDING_FAILURE_MESSAGES[code]}; {'; '.join(identifiers)}", code


def _parse_structured_stats(line: str, prefix: str) -> dict[str, Any] | None:
    marker = line.find(prefix)
    if marker < 0:
        return None
    payload = line[marker + len(prefix):].strip()
    if not payload or len(payload) > 256 * 1024:
        return None
    try:
        value = json.loads(payload)
    except (TypeError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _validate_integer_only_summary(value: Any) -> None:
    if isinstance(value, bool) or value is None or isinstance(value, float):
        raise ValueError("building preprocessing manifest summary is not integer-safe")
    if isinstance(value, (str, int)):
        return
    if isinstance(value, list):
        for item in value:
            _validate_integer_only_summary(item)
        return
    if isinstance(value, dict) and all(isinstance(key, str) for key in value):
        for item in value.values():
            _validate_integer_only_summary(item)
        return
    raise ValueError("building preprocessing manifest summary has an unsupported value")


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
        building_scope_mode: str = "shadow",
    ):
        self.paths = paths
        self.runner = runner or CommandRunner()
        self.source_cache = source_cache or SourceCache(paths.repo_root)
        self.artifact_store = artifact_store
        self.map_signer = map_signer
        self.producer_build_sha256 = producer_build_sha256
        self.producer_image_digest = producer_image_digest
        self.source_preview_geometry_resolver = source_preview_geometry_resolver
        if building_scope_mode not in {"legacy", "shadow", "selected"}:
            raise ValueError("building scope mode must be legacy, shadow, or selected")
        self.building_scope_mode = building_scope_mode
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
        on_phase_progress=None,
        on_artifact_pending=None,
        artifact_publication_lease=None,
        cancellation_check=None,
    ) -> MapBuildResult:
        build_started_monotonic = time.monotonic()
        building_phase_timings: dict[str, float] = {}
        if self.uses_selected_preprocessing(job) and on_phase_progress is not None:
            external_phase_progress = on_phase_progress
            observability = getattr(job, "_building_observability", None)
            if observability is None:
                observability = {"attemptStartedMonotonic": build_started_monotonic}
                job._building_observability = observability

            def record_phase_progress(progress):
                if "firstProgressMilliseconds" not in observability:
                    attempt_started = observability.get(
                        "attemptStartedMonotonic", build_started_monotonic
                    )
                    observability["firstProgressMilliseconds"] = max(
                        0,
                        int(round((time.monotonic() - attempt_started) * 1_000)),
                    )
                if external_phase_progress is not None:
                    external_phase_progress(progress)

            on_phase_progress = record_phase_progress
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
        format_version = renderer_format_version(job.request)
        processing_bounds = aligned_processing_bounds(
            job,
            complete_blocks=format_version == BUILDING_RENDERER_FORMAT_VERSION,
        )
        scope_plan: ScopePlan | None = None
        scope_diagnostics: dict[str, Any] | None = None
        planned_scope_marker: dict[str, Any] | None = None
        selected_scope = False
        if format_version == BUILDING_RENDERER_FORMAT_VERSION:
            calibration = load_building_calibration_window(
                self.paths.osm_extract_root / "conf" / "building_height_rules.yaml"
            )
            legacy_scope = legacy_building_scope_diagnostics(
                job,
                calibration_cell_size_meters=calibration.cell_size_meters,
                calibration_halo_cells=calibration.halo_cells,
            )
            if self.building_scope_mode != "legacy":
                try:
                    scope_plan = self._plan_selected_scope(job, calibration)
                    scope_diagnostics = {
                        "mode": self.building_scope_mode,
                        "scope": scope_plan.summary(),
                        "legacyScope": legacy_scope,
                    }
                except BuildingScopeError as exc:
                    if self.building_scope_mode == "selected":
                        raise
                    scope_diagnostics = {
                        "mode": "shadow",
                        "errorCode": exc.code,
                        "legacyScope": legacy_scope,
                    }
            selected_scope = self.building_scope_mode == "selected"
            if selected_scope:
                if scope_plan is None:
                    raise BuildingScopeError(
                        "building_scope_policy_invalid",
                        "selected target-3 extraction requires a scope plan",
                    )
                source_bounds = scope_plan.source_bounds
                scope_summary = scope_plan.summary()
                planned_scope_marker = {
                    key: scope_summary[key]
                    for key in (
                        "scopePlanSha256",
                        "outputBlockCount",
                        "requestedApproximateAreaM2",
                        "outputAreaM2",
                        "sourceAreaM2",
                        "sourceToOutputAreaBasisPoints",
                        "calibrationCellCount",
                        "calibrationSampleCellCount",
                        "geometryBufferMeters",
                        "sourceBoundsE7",
                    )
                }
                print(
                    "BUILDING_SCOPE:"
                    + canonical_building_json(planned_scope_marker).decode("utf-8"),
                    flush=True,
                )
                self._emit_phase_progress(
                    on_phase_progress,
                    unit="scope_plan",
                    completed=1,
                    total=1,
                    total_blocks=len(scope_plan.output_blocks),
                    indeterminate=False,
                )
            else:
                source_bounds = expanded_building_source_bounds(
                    processing_bounds,
                    cell_size_meters=calibration.cell_size_meters,
                    halo_cells=calibration.halo_cells,
                )
        else:
            source_bounds = processing_bounds

        if job_dir.exists():
            shutil.rmtree(job_dir)
        job_dir.mkdir(parents=True)
        if scope_plan is not None:
            scope_plan_path = job_dir / "scope-plan.json"
            scope_plan.write(scope_plan_path)
        else:
            scope_plan_path = None

        if on_status and not selected_scope:
            on_status(JobStatus.RESOLVING_SOURCE)
        if selected_scope:
            cached_source = self._cached_source_for_job(job)
            source_pbf = cached_source.path
            source_snapshot_sha256 = cached_source.sha256
            calibration_generation_execution: dict[str, Any] = {}
            (
                _,
                calibration_generation,
            ) = self._ensure_selected_calibration_generation(
                source_pbf,
                source_snapshot_sha256,
                scope_plan,
                **(
                    {"on_phase_progress": on_phase_progress}
                    if on_phase_progress is not None
                    else {}
                ),
                execution_sink=calibration_generation_execution,
                cancellation_check=cancellation_check,
            )
            if job.building_preprocessing_runtime is None:
                job.building_preprocessing_runtime = {
                    "calibrationGeneration": calibration_generation_execution
                }
            self._freeze_selected_inputs(
                job,
                source_snapshot_sha256=source_snapshot_sha256,
                scope_plan=scope_plan,
                calibration_generation=calibration_generation,
            )
            building_identity = selected_building_identity(
                source_snapshot_sha256=source_snapshot_sha256,
                rules_path=(
                    self.paths.osm_extract_root
                    / "conf"
                    / "building_height_rules.yaml"
                ),
                scope_plan=scope_plan,
                calibration_generation=calibration_generation,
            )
            if job.build_cache_key is not None or job.build_compatibility_key is not None:
                expected_build_keys = reuse_keys(
                    job,
                    producer_build_sha256=self.producer_build_sha256,
                    producer_image_digest=self.producer_image_digest,
                    source_snapshot_sha256=source_snapshot_sha256,
                    building_preprocessing_identity=building_identity,
                )
                if (
                    expected_build_keys is None
                    or expected_build_keys.exact != job.build_cache_key
                    or expected_build_keys.compatibility
                    != job.build_compatibility_key
                ):
                    raise BuildingScopeError(
                        "building_source_snapshot_changed",
                        "selected building inputs changed after build identity reservation",
                    )
            scope_diagnostics["identity"] = building_identity
        else:
            source_pbf = self._source_pbf_path(job)
            source_snapshot_sha256 = None
            building_identity = None
            calibration_generation = None
            if self.building_scope_mode == "shadow" and scope_plan is not None:
                shadow_execution: dict[str, Any] = {}
                shadow_measurement_started = time.perf_counter()
                try:
                    source_snapshot_sha256 = sha256_file(source_pbf)
                    (
                        _,
                        shadow_calibration_generation,
                    ) = self._ensure_selected_calibration_generation(
                        source_pbf,
                        source_snapshot_sha256,
                        scope_plan,
                        execution_sink=shadow_execution,
                        on_phase_progress=on_phase_progress,
                        cancellation_check=cancellation_check,
                    )
                    shadow_dependency_started = time.perf_counter()
                    shadow_requirements = self._selected_dependency_metrics(
                        source_pbf,
                        source_snapshot_sha256,
                        scope_plan,
                        shadow_calibration_generation,
                        on_phase_progress=on_phase_progress,
                        cancellation_check=cancellation_check,
                    )
                    shadow_requirements["dependencyValidationExecution"] = {
                        "durationSeconds": round(
                            time.perf_counter() - shadow_dependency_started, 6
                        )
                    }
                    shadow_requirements["calibrationGenerationExecution"] = (
                        shadow_execution
                    )
                    scope_diagnostics["shadowRequirements"] = shadow_requirements
                except (
                    BuildingScopeError,
                    SourceCacheError,
                    SubsetReuseUnavailable,
                    KeyError,
                    OSError,
                    RuntimeError,
                    TypeError,
                    ValueError,
                    subprocess.CalledProcessError,
                ) as exc:
                    if cancellation_check is not None and cancellation_check():
                        raise
                    scope_diagnostics["shadowMeasurementError"] = {
                        "code": getattr(
                            exc, "code", "building_shadow_measurement_unavailable"
                        )
                    }
                finally:
                    scope_diagnostics["shadowMeasurementExecution"] = {
                        "durationSeconds": round(
                            time.perf_counter() - shadow_measurement_started, 6
                        )
                    }
        if on_status and not selected_scope:
            on_status(JobStatus.EXTRACTING_PBF)
        source_extraction_started = time.perf_counter()
        try:
            if format_version == BUILDING_RENDERER_FORMAT_VERSION:
                extract_kwargs = {"bounds": source_bounds, "force_bounds": True}
                if selected_scope:
                    extract_kwargs["scope_plan"] = scope_plan
                    extract_kwargs["source_snapshot_sha256"] = source_snapshot_sha256
                if cancellation_check is not None:
                    extract_kwargs["cancellation_check"] = cancellation_check
                self._extract_pbf(
                    job,
                    source_pbf,
                    clipped_pbf,
                    **extract_kwargs,
                )
            else:
                extract_kwargs = {"bounds": source_bounds}
                if cancellation_check is not None:
                    extract_kwargs["cancellation_check"] = cancellation_check
                self._extract_pbf(
                    job,
                    source_pbf,
                    clipped_pbf,
                    **extract_kwargs,
                )
        except BuildingScopeError:
            raise
        except (OSError, subprocess.CalledProcessError) as exc:
            if not selected_scope:
                raise
            raise BuildingScopeError(
                "building_relation_incomplete",
                "selected building source extraction failed",
            ) from exc
        if selected_scope:
            building_phase_timings["sourceExtraction"] = (
                time.perf_counter() - source_extraction_started
            )
        if on_status:
            on_status(JobStatus.CONVERTING_FEATURES)
        calibration_manifest = None
        source_index_manifest = None
        preprocessing_metrics = None
        relation_retries: list[dict[str, Any]] = []
        if selected_scope:
            assert scope_plan_path is not None
            assert source_snapshot_sha256 is not None
            preprocessing_started = time.perf_counter()
            (
                calibration_manifest,
                source_index_manifest,
                preprocessing_metrics,
            ) = self._prepare_selected_building_inputs(
                source_pbf,
                clipped_pbf,
                source_snapshot_sha256,
                scope_plan_path,
                job_dir,
                expected_calibration_generation=calibration_generation,
                cancellation_check=cancellation_check,
                **(
                    {"on_phase_progress": on_phase_progress}
                    if on_phase_progress is not None
                    else {}
                ),
            )
            building_phase_timings["preprocessing"] = (
                time.perf_counter() - preprocessing_started
            )
        conversion_started = time.perf_counter()
        while True:
            conversion_kwargs = {"bounds": source_bounds}
            if selected_scope:
                conversion_kwargs.update(
                    {
                        "source_index_manifest": source_index_manifest,
                        "scope_plan_path": scope_plan_path,
                        "relation_retry_count": len(relation_retries),
                    }
                )
            if cancellation_check is not None:
                conversion_kwargs["cancellation_check"] = cancellation_check
            try:
                self._convert_to_geojson(
                    job,
                    clipped_pbf,
                    geojson_prefix,
                    **conversion_kwargs,
                )
                break
            except subprocess.CalledProcessError as exc:
                output = "\n".join(
                    part
                    for part in (
                        getattr(exc, "stdout", None),
                        getattr(exc, "stderr", None),
                        getattr(exc, "output", None),
                    )
                    if isinstance(part, str)
                )
                failure = parse_building_failure(output)
                if not selected_scope:
                    raise
                if failure is None:
                    raise BuildingScopeError(
                        "building_relation_incomplete",
                        "selected building feature conversion failed",
                    ) from exc
                if failure["code"] != "building_relation_incomplete":
                    raise BuildingScopeError(
                        failure["code"], failure["message"]
                    ) from exc
                if (
                    scope_plan is None
                    or scope_plan_path is None
                    or source_snapshot_sha256 is None
                ):
                    raise BuildingScopeError(
                        "building_scope_policy_invalid",
                        "selected building retry scope is unavailable",
                    ) from exc
                policy = scope_plan.document["policy"]
                current_buffer = (
                    relation_retries[-1]["bufferMeters"]
                    if relation_retries
                    else policy["geometryBufferMeters"]
                )
                retry_buffers = (
                    policy["relationRetryBufferMeters"],
                    policy["maxGeometryBufferMeters"],
                )
                next_buffer = next(
                    (value for value in retry_buffers if value > current_buffer),
                    None,
                )
                if next_buffer is None:
                    raise BuildingScopeError(
                        "building_relation_incomplete",
                        "building relation closure remains incomplete after bounded retries",
                    ) from exc
                retry_started = time.monotonic()
                try:
                    attempt_scope_plan = plan_building_scope(
                        job,
                        calibration_cell_size_meters=calibration.cell_size_meters,
                        calibration_halo_cells=calibration.halo_cells,
                        calibration_minimum_samples=calibration.minimum_samples,
                        geometry_buffer_meters=next_buffer,
                    )
                except BuildingScopeError as planning_error:
                    raise BuildingScopeError(
                        "building_relation_incomplete",
                        "building relation closure cannot expand within source-scope limits",
                    ) from planning_error
                source_bounds = attempt_scope_plan.source_bounds
                retry_extract_kwargs = {
                    "bounds": source_bounds,
                    "force_bounds": True,
                    "scope_plan": attempt_scope_plan,
                    "source_snapshot_sha256": source_snapshot_sha256,
                }
                if cancellation_check is not None:
                    retry_extract_kwargs["cancellation_check"] = (
                        cancellation_check
                    )
                self._extract_pbf(
                    job,
                    source_pbf,
                    clipped_pbf,
                    **retry_extract_kwargs,
                )
                attempt_scope_plan.write(scope_plan_path)
                (
                    calibration_manifest,
                    source_index_manifest,
                    attempt_preprocessing_metrics,
                ) = self._prepare_selected_building_inputs(
                    source_pbf,
                    clipped_pbf,
                    source_snapshot_sha256,
                    scope_plan_path,
                    job_dir,
                    expected_calibration_generation=calibration_generation,
                    cancellation_check=cancellation_check,
                    **(
                        {"on_phase_progress": on_phase_progress}
                        if on_phase_progress is not None
                        else {}
                    ),
                )
                attempt_summary = attempt_scope_plan.summary()
                attempt_artifact_scope = {
                    "scopePlanSha256": attempt_scope_plan.sha256,
                    "sourceAreaM2": attempt_summary["sourceAreaM2"],
                    "sourceToOutputAreaBasisPoints": attempt_summary[
                        "sourceToOutputAreaBasisPoints"
                    ],
                    "geometryBufferMeters": next_buffer,
                    "sourceBoundsE7": attempt_summary["sourceBoundsE7"],
                    "closurePlanSha256": attempt_preprocessing_metrics.get(
                        "closure", {}
                    ).get("closurePlanSha256"),
                }
                if attempt_artifact_scope["closurePlanSha256"] is not None:
                    scope_diagnostics["attemptScope"] = attempt_artifact_scope
                    if job.build_cache_key is not None:
                        base_exact_key = (
                            job.build_cache_aliases[0]
                            if job.build_cache_aliases
                            else job.build_cache_key
                        )
                        job.build_cache_key = hashlib.sha256(
                            canonical_building_json(
                                {
                                    "baseExactKey": base_exact_key,
                                    "strategy": "bounded_relation_retry",
                                    "attemptScope": attempt_artifact_scope,
                                }
                            )
                        ).hexdigest()
                        job.build_cache_aliases = [base_exact_key]
                        job.build_identity_derivation = {
                            "baseExactKey": base_exact_key,
                            "strategy": "bounded_relation_retry",
                            "attemptScope": attempt_artifact_scope,
                        }
                retry_record = {
                    "attempt": len(relation_retries) + 1,
                    "bufferMeters": next_buffer,
                    "reasonCode": failure["code"],
                    "durationMilliseconds": max(
                        0, int(round((time.monotonic() - retry_started) * 1000))
                    ),
                    "attemptScopePlanSha256": attempt_scope_plan.sha256,
                    "sourceAreaM2": attempt_summary["sourceAreaM2"],
                    "sourceBoundsE7": attempt_summary["sourceBoundsE7"],
                }
                if isinstance(attempt_preprocessing_metrics.get("closure"), dict):
                    retry_record["closure"] = attempt_preprocessing_metrics["closure"]
                relation_retries.append(retry_record)
        if selected_scope:
            building_phase_timings["conversion"] = (
                time.perf_counter() - conversion_started
            )
        feature_kwargs = {"bounds": processing_bounds, "on_progress": on_progress}
        if (
            format_version == BUILDING_RENDERER_FORMAT_VERSION
            and on_phase_progress is not None
        ):
            feature_kwargs["on_phase_progress"] = on_phase_progress
        if selected_scope:
            feature_kwargs.update(
                {
                    "scope_plan_path": scope_plan_path,
                    "calibration_manifest": calibration_manifest,
                    "calibration_source_sha256": source_snapshot_sha256,
                    "planned_scope_marker": planned_scope_marker,
                }
            )
        if cancellation_check is not None:
            feature_kwargs["cancellation_check"] = cancellation_check
        try:
            label_metrics = self._extract_features(
                job, geojson_prefix, raw_output_dir, **feature_kwargs
            )
        except subprocess.CalledProcessError as exc:
            if not selected_scope:
                raise
            output = "\n".join(
                value
                for value in (
                    getattr(exc, "stdout", None),
                    getattr(exc, "stderr", None),
                    getattr(exc, "output", None),
                )
                if isinstance(value, str)
            )
            failure = parse_building_failure(output)
            raise BuildingScopeError(
                failure["code"] if failure else "building_calibration_unavailable",
                failure["message"] if failure else "selected building encoding failed",
            ) from exc
        if selected_scope:
            if planned_scope_marker is not None:
                label_metrics["buildingScope"] = planned_scope_marker
            script_phase_timings = label_metrics.pop(
                "buildingScriptPhaseTimings", {}
            )
            building_phase_timings.update(script_phase_timings)
            emitted_scope = label_metrics.get("buildingScope")
            if (
                not isinstance(emitted_scope, dict)
                or emitted_scope.get("scopePlanSha256") != scope_plan.sha256
                or emitted_scope.get("outputBlockCount")
                != len(scope_plan.output_blocks)
            ):
                raise BuildingScopeError(
                    "building_scope_policy_invalid",
                    "encoded building scope does not match the frozen scope plan",
                )
        if scope_diagnostics is not None:
            label_metrics["buildingPreprocessing"] = scope_diagnostics
        if preprocessing_metrics is not None:
            label_metrics.setdefault("buildingPreprocessing", {}).update(
                preprocessing_metrics
            )
            label_metrics["buildingPreprocessing"]["relationRetries"] = relation_retries
        if selected_scope:
            runtime_metrics = job.building_preprocessing_runtime or {}
            calibration_generation_execution = runtime_metrics.get(
                "calibrationGeneration"
            )
            if isinstance(calibration_generation_execution, dict):
                label_metrics.setdefault("buildingPreprocessing", {})[
                    "calibrationGenerationExecution"
                ] = deepcopy(calibration_generation_execution)
                duration = calibration_generation_execution.get(
                    "durationSeconds"
                )
                if (
                    isinstance(duration, (int, float))
                    and not isinstance(duration, bool)
                    and math.isfinite(float(duration))
                    and duration >= 0
                ):
                    building_phase_timings["calibrationGeneration"] = float(
                        duration
                    )
            preprocessing_observability = getattr(
                job, "_building_observability", {}
            )
            label_metrics["buildingPhaseTimings"] = {
                key: round(value, 6)
                for key, value in building_phase_timings.items()
            }
            label_metrics["buildingObservability"] = {
                "firstProgressMilliseconds": preprocessing_observability.get(
                    "firstProgressMilliseconds", 0
                ),
                "cacheWaitMilliseconds": preprocessing_observability.get(
                    "cacheWaitMilliseconds", 0
                ),
                "retryMilliseconds": sum(
                    retry["durationMilliseconds"] for retry in relation_retries
                ),
            }
        if on_status:
            on_status(JobStatus.PACKAGING)
        self._stage_vectmap(raw_output_dir, vectmap_output)

        return self._package_map(
            job,
            pack_root,
            archive_path,
            artifact_publication_lease=artifact_publication_lease,
            on_artifact_pending=on_artifact_pending,
            build_metrics=label_metrics,
        )

    def uses_selected_preprocessing(self, job: MapJob) -> bool:
        if (
            renderer_format_version(job.request)
            != BUILDING_RENDERER_FORMAT_VERSION
        ):
            return False
        frozen_mode = job.building_preprocessing_mode
        if frozen_mode is None:
            job.building_preprocessing_mode = self.building_scope_mode
        elif frozen_mode != self.building_scope_mode:
            raise BuildingScopeError(
                "building_scope_policy_invalid",
                "building preprocessing rollout mode changed before retry",
            )
        return self.building_scope_mode == "selected"

    @staticmethod
    def _attempt_id(job: MapJob) -> str:
        return re.sub(
            r"[^a-zA-Z0-9_-]",
            "-",
            job.worker_id or f"attempt-{job.attempts}",
        )

    def cleanup_failed_attempt(self, job: MapJob) -> bool:
        """Remove only this job attempt's temporary work directory."""
        attempt_root = self.paths.work_root / job.job_id / self._attempt_id(job)
        if not attempt_root.exists():
            return False
        shutil.rmtree(attempt_root)
        job_root = attempt_root.parent
        try:
            job_root.rmdir()
        except OSError:
            pass
        return True

    def _plan_selected_scope(self, job: MapJob, calibration=None) -> ScopePlan:
        calibration = calibration or load_building_calibration_window(
            self.paths.osm_extract_root / "conf" / "building_height_rules.yaml"
        )
        scope_plan = plan_building_scope(
            job,
            calibration_cell_size_meters=calibration.cell_size_meters,
            calibration_halo_cells=calibration.halo_cells,
            calibration_minimum_samples=calibration.minimum_samples,
        )
        frozen = job.building_preprocessing_inputs
        if frozen is not None:
            expected_scope = frozen.get("scopePlan")
            serialized_scope = {
                **scope_plan.document,
                "scopePlanSha256": scope_plan.sha256,
            }
            if expected_scope != serialized_scope:
                raise BuildingScopeError(
                    "building_scope_policy_invalid",
                    "frozen building scope changed before retry",
                )
        return scope_plan

    @staticmethod
    def _freeze_selected_inputs(
        job: MapJob,
        *,
        source_snapshot_sha256: str,
        scope_plan: ScopePlan,
        calibration_generation: dict[str, Any],
    ) -> None:
        frozen = {
            "schemaVersion": 1,
            "sourceSnapshotSha256": source_snapshot_sha256,
            "scopePlan": {
                **scope_plan.document,
                "scopePlanSha256": scope_plan.sha256,
            },
            "calibrationGeneration": deepcopy(calibration_generation),
        }
        previous = job.building_preprocessing_inputs
        if previous is None:
            job.building_preprocessing_inputs = frozen
            return
        if previous.get("sourceSnapshotSha256") != source_snapshot_sha256:
            raise BuildingScopeError(
                "building_source_snapshot_changed",
                "frozen source snapshot changed before retry",
            )
        if previous.get("scopePlan") != frozen["scopePlan"]:
            raise BuildingScopeError(
                "building_scope_policy_invalid",
                "frozen building scope changed before retry",
            )
        if previous.get("calibrationGeneration") != calibration_generation:
            raise BuildingScopeError(
                "building_calibration_unavailable",
                "frozen calibration generation changed before retry",
            )

    def _selected_total_blocks(self, job: MapJob) -> int | None:
        if not self.uses_selected_preprocessing(job):
            return None
        calibration = load_building_calibration_window(
            self.paths.osm_extract_root / "conf" / "building_height_rules.yaml"
        )
        scope_plan = self._plan_selected_scope(job, calibration)
        return len(scope_plan.output_blocks)

    @staticmethod
    def _emit_phase_progress(
        callback,
        *,
        unit: str,
        completed: int | None,
        total: int | None,
        total_blocks: int | None,
        indeterminate: bool,
        phase: str = "building_preprocessing",
    ) -> None:
        if callback is None:
            return
        progress = {
            "phase": phase,
            "unit": unit,
            "completed": completed,
            "total": total,
            "completedBlocks": 0 if total_blocks is not None else None,
            "totalBlocks": total_blocks,
            "indeterminate": indeterminate,
        }
        callback(progress)

    def reuse_keys(
        self,
        job: MapJob,
        *,
        on_phase_progress=None,
        cancellation_check=None,
    ) -> MapReuseKeys | None:
        format_version = renderer_format_version(job.request)
        selected_target_three = self.uses_selected_preprocessing(job)
        producer_identity_available = bool(
            re.fullmatch(r"[0-9a-f]{64}", self.producer_build_sha256 or "")
            and re.fullmatch(
                r"sha256:[0-9a-f]{64}",
                self.producer_image_digest or "",
            )
        )
        if not selected_target_three and not producer_identity_available:
            return None
        self._resolve_source_preview_geometry(job)
        source_snapshot_sha256 = job.source_region.checksum
        resolved_source = None
        if selected_target_three:
            self._emit_phase_progress(
                on_phase_progress,
                unit="source_cache_wait",
                completed=None,
                total=None,
                total_blocks=self._selected_total_blocks(job),
                indeterminate=True,
            )
            cache_wait_started = time.monotonic()
            try:
                resolved_source = self.source_cache.ensure(
                    job.source_region,
                    cancellation_check=cancellation_check,
                )
            finally:
                observability = getattr(job, "_building_observability", None)
                if observability is None:
                    observability = {}
                    job._building_observability = observability
                observability["cacheWaitMilliseconds"] = (
                    observability.get("cacheWaitMilliseconds", 0)
                    + max(
                        0,
                        int(
                            round(
                                (time.monotonic() - cache_wait_started) * 1_000
                            )
                        ),
                    )
                )
            source_snapshot_sha256 = resolved_source.sha256
        if not re.fullmatch(r"[0-9a-f]{64}", source_snapshot_sha256 or ""):
            resolved_source = resolved_source or self.source_cache.ensure(
                job.source_region,
                cancellation_check=cancellation_check,
            )
            source_snapshot_sha256 = resolved_source.sha256
        building_identity = None
        if selected_target_three:
            keys = self._reuse_keys_for_cached_source(
                job,
                resolved_source,
                on_phase_progress=on_phase_progress,
                cancellation_check=cancellation_check,
            )
            return keys if producer_identity_available else None
        return reuse_keys(
            job,
            producer_build_sha256=self.producer_build_sha256,
            producer_image_digest=self.producer_image_digest,
            source_snapshot_sha256=source_snapshot_sha256,
            building_preprocessing_identity=building_identity,
            preview_sha256=self._freeze_preview_identity(job),
        )

    def _reuse_keys_for_cached_source(
        self,
        job: MapJob,
        cached_source,
        *,
        on_phase_progress=None,
        cancellation_check=None,
    ) -> MapReuseKeys | None:
        self._resolve_source_preview_geometry(job)
        source_snapshot_sha256 = cached_source.sha256
        frozen_inputs = job.building_preprocessing_inputs
        if (
            frozen_inputs is not None
            and frozen_inputs.get("sourceSnapshotSha256")
            != source_snapshot_sha256
        ):
            raise BuildingScopeError(
                "building_source_snapshot_changed",
                "frozen source snapshot changed before retry",
            )
        building_identity = None
        if (
            renderer_format_version(job.request)
            == BUILDING_RENDERER_FORMAT_VERSION
            and self.building_scope_mode == "selected"
        ):
            calibration = load_building_calibration_window(
                self.paths.osm_extract_root / "conf" / "building_height_rules.yaml"
            )
            scope_plan = self._plan_selected_scope(job, calibration)
            calibration_generation_execution: dict[str, Any] = {}
            _, calibration_generation = self._ensure_selected_calibration_generation(
                cached_source.path,
                source_snapshot_sha256,
                scope_plan,
                **(
                    {"on_phase_progress": on_phase_progress}
                    if on_phase_progress is not None
                    else {}
                ),
                execution_sink=calibration_generation_execution,
                cancellation_check=cancellation_check,
            )
            if job.building_preprocessing_runtime is None:
                job.building_preprocessing_runtime = {
                    "calibrationGeneration": calibration_generation_execution
                }
            self._freeze_selected_inputs(
                job,
                source_snapshot_sha256=source_snapshot_sha256,
                scope_plan=scope_plan,
                calibration_generation=calibration_generation,
            )
            building_identity = selected_building_identity(
                source_snapshot_sha256=source_snapshot_sha256,
                rules_path=(
                    self.paths.osm_extract_root
                    / "conf"
                    / "building_height_rules.yaml"
                ),
                scope_plan=scope_plan,
                calibration_generation=calibration_generation,
            )
        return reuse_keys(
            job,
            producer_build_sha256=self.producer_build_sha256,
            producer_image_digest=self.producer_image_digest,
            source_snapshot_sha256=source_snapshot_sha256,
            building_preprocessing_identity=building_identity,
            preview_sha256=self._freeze_preview_identity(job),
        )

    @contextmanager
    def exact_reuse_identity_lease(
        self,
        job: MapJob,
        *,
        on_phase_progress=None,
        cancellation_check=None,
    ):
        if re.fullmatch(r"[0-9a-f]{64}", job.source_region.checksum or ""):
            yield self.reuse_keys(
                job,
                on_phase_progress=on_phase_progress,
                cancellation_check=cancellation_check,
            )
            return
        if self.uses_selected_preprocessing(job):
            self._emit_phase_progress(
                on_phase_progress,
                unit="source_cache_wait",
                completed=None,
                total=None,
                total_blocks=self._selected_total_blocks(job),
                indeterminate=True,
            )
        cache_wait_started = time.monotonic()
        try:
            with self.source_cache.verified_lease(
                job.source_region,
                cancellation_check=cancellation_check,
            ) as cached_source:
                cache_wait_milliseconds = max(
                    0,
                    int(round((time.monotonic() - cache_wait_started) * 1_000)),
                )
                observability = getattr(job, "_building_observability", None)
                if observability is None:
                    observability = {}
                    job._building_observability = observability
                observability["cacheWaitMilliseconds"] = (
                    observability.get("cacheWaitMilliseconds", 0)
                    + cache_wait_milliseconds
                )
                job._leased_cached_source = cached_source
                try:
                    yield self._reuse_keys_for_cached_source(
                        job,
                        cached_source,
                        on_phase_progress=on_phase_progress,
                        cancellation_check=cancellation_check,
                    )
                finally:
                    del job._leased_cached_source
        except BaseException:
            observability = getattr(job, "_building_observability", None)
            if observability is not None and "cacheWaitMilliseconds" not in observability:
                observability["cacheWaitMilliseconds"] = max(
                    0,
                    int(round((time.monotonic() - cache_wait_started) * 1_000)),
                )
            raise

    def validate_exact_reuse_candidate(self, job: MapJob, candidate: MapJob) -> bool:
        if (
            candidate.map_id != stable_map_id(candidate)
            or candidate.map_id != stable_map_id(job)
        ):
            return False
        self.paths.work_root.mkdir(parents=True, exist_ok=True)
        if self.artifact_store is not None and any(
            not self.artifact_store.verify(
                artifact.object_key,
                sha256=artifact.sha256,
                expected_bytes=artifact.bytes,
            )
            for artifact in candidate.artifacts
        ):
            return False
        original_map_id = job.map_id
        job.map_id = stable_map_id(job)
        try:
            with tempfile.TemporaryDirectory(
                prefix="exact-reuse-validation-",
                dir=self.paths.work_root,
            ) as temporary:
                pack_root = Path(temporary) / "pack"
                manifest = self._stage_subset_pack(job, candidate, pack_root)
                expected_build_identity = build_identity_manifest(
                    candidate, manifest.get("buildingPreprocessing")
                )
                if manifest.get("buildIdentity") != expected_build_identity:
                    return False
                if candidate.build_cache_aliases:
                    base_keys = self._derived_candidate_base_keys(candidate, manifest)
                    if (
                        base_keys is None
                        or candidate.build_cache_aliases != [base_keys.exact]
                        or candidate.build_compatibility_key
                        != base_keys.compatibility
                    ):
                        return False
                build_manifest(job, pack_root, self._pipeline_metadata())
            return True
        except (OSError, RuntimeError, SubsetReuseUnavailable, ValueError):
            return False
        finally:
            job.map_id = original_map_id

    def _derived_candidate_base_keys(
        self,
        candidate: MapJob,
        manifest: dict[str, Any],
    ) -> MapReuseKeys | None:
        summary = manifest.get("buildingPreprocessing")
        preview = manifest.get("preview")
        if (
            self.building_scope_mode != "selected"
            or renderer_format_version(candidate.request)
            != BUILDING_RENDERER_FORMAT_VERSION
            or not isinstance(summary, dict)
            or not isinstance(preview, dict)
        ):
            return None
        try:
            calibration = load_building_calibration_window(
                self.paths.osm_extract_root / "conf" / "building_height_rules.yaml"
            )
            scope_plan = self._plan_selected_scope(candidate, calibration)
            calibration_generation = {
                key: summary["calibration"][key]
                for key in (
                    "calibrationKey",
                    "manifestSha256",
                    "entrySetSha256",
                    "cellCount",
                )
            }
            identity = selected_building_identity(
                source_snapshot_sha256=summary["sourceSnapshotSha256"],
                rules_path=(
                    self.paths.osm_extract_root
                    / "conf"
                    / "building_height_rules.yaml"
                ),
                scope_plan=scope_plan,
                calibration_generation=calibration_generation,
            )
            closure = dict(summary["closure"])
            closure.pop("relationRetryCount", None)
            metrics = {
                "mode": "selected",
                "scope": scope_plan.summary(),
                "identity": identity,
                "sourceIndex": summary["sourceIndex"],
                "closure": closure,
                "calibration": summary["calibration"],
            }
            if "attemptScope" in summary:
                metrics["attemptScope"] = summary["attemptScope"]
            if self._building_preprocessing_summary(metrics) != summary:
                return None
            return reuse_keys(
                candidate,
                producer_build_sha256=self.producer_build_sha256,
                producer_image_digest=self.producer_image_digest,
                source_snapshot_sha256=summary["sourceSnapshotSha256"],
                building_preprocessing_identity=identity,
                preview_sha256=preview.get("sha256"),
            )
        except (KeyError, TypeError, ValueError):
            return None

    def build_subset(
        self,
        job: MapJob,
        parent: MapJob,
        *,
        on_status=None,
        on_progress=None,
        on_phase_progress=None,
        on_artifact_pending=None,
        artifact_publication_lease=None,
        cancellation_check=None,
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
        parent_manifest = self._stage_subset_pack(job, parent, pack_root)
        subset_block_count = sum(1 for _ in pack_root.rglob("*.fmb"))
        self._emit_phase_progress(
            on_phase_progress,
            phase="block_encoding",
            unit="subset_blocks",
            completed=0,
            total=subset_block_count,
            total_blocks=subset_block_count,
            indeterminate=False,
        )
        try:
            build_manifest(job, pack_root, self._pipeline_metadata())
        except (OSError, RuntimeError, ValueError) as exc:
            raise SubsetReuseUnavailable(
                "parent map renderer composition is invalid"
            ) from exc
        if on_progress:
            on_progress(subset_block_count, subset_block_count)
        build_metrics = self._subset_build_metrics(
            job,
            parent,
            parent_manifest,
            on_phase_progress=on_phase_progress,
            cancellation_check=cancellation_check,
        ) or {}
        self._add_current_building_attempt_metrics(build_metrics, job)
        subset_build_cache_key = build_metrics.pop("subsetBuildCacheKey", None)
        subset_build_cache_alias = build_metrics.pop("subsetBuildCacheAlias", None)
        original_build_cache_key = job.build_cache_key
        original_build_cache_aliases = list(job.build_cache_aliases)
        original_build_identity_derivation = job.build_identity_derivation
        if subset_build_cache_key is not None:
            job.build_cache_key = subset_build_cache_key
        if subset_build_cache_alias is not None:
            job.build_cache_aliases = [subset_build_cache_alias]
            job.build_identity_derivation = build_metrics.pop(
                "subsetBuildIdentityDerivation"
            )
        try:
            return self._package_map(
                job,
                pack_root,
                archive_path,
                artifact_publication_lease=artifact_publication_lease,
                on_artifact_pending=on_artifact_pending,
                build_metrics=build_metrics,
            )
        except Exception:
            job.build_cache_key = original_build_cache_key
            job.build_cache_aliases = original_build_cache_aliases
            job.build_identity_derivation = original_build_identity_derivation
            raise

    @staticmethod
    def _add_current_building_attempt_metrics(
        build_metrics: dict[str, Any], job: MapJob
    ) -> None:
        runtime_metrics = job.building_preprocessing_runtime or {}
        for timing_name in ("calibrationGeneration", "dependencyValidation"):
            execution = runtime_metrics.get(timing_name)
            if not isinstance(execution, dict):
                continue
            build_metrics.setdefault("buildingPreprocessing", {})[
                f"{timing_name}Execution"
            ] = deepcopy(execution)
            duration = execution.get("durationSeconds")
            if (
                isinstance(duration, (int, float))
                and not isinstance(duration, bool)
                and math.isfinite(float(duration))
                and duration >= 0
            ):
                build_metrics.setdefault("buildingPhaseTimings", {})[
                    timing_name
                ] = float(duration)
        current_observability = getattr(job, "_building_observability", {})
        build_metrics["buildingObservability"] = {
            key: int(current_observability[key])
            for key in (
                "firstProgressMilliseconds",
                "cacheWaitMilliseconds",
            )
            if isinstance(current_observability.get(key), int)
            and not isinstance(current_observability.get(key), bool)
            and current_observability[key] >= 0
        }

    def _subset_build_metrics(
        self,
        job: MapJob,
        parent: MapJob,
        parent_manifest: dict[str, Any],
        *,
        on_phase_progress=None,
        cancellation_check=None,
    ) -> dict[str, Any] | None:
        if (
            self.building_scope_mode != "selected"
            or renderer_format_version(job.request)
            != BUILDING_RENDERER_FORMAT_VERSION
        ):
            return None
        parent_summary = parent_manifest.get("buildingPreprocessing")
        parent_build_identity = parent_manifest.get("buildIdentity")
        try:
            expected_parent_build_identity = build_identity_manifest(
                parent,
                parent_summary if isinstance(parent_summary, dict) else None,
            )
        except ValueError as exc:
            raise SubsetReuseUnavailable(
                "parent map build identity is invalid"
            ) from exc
        if (
            not isinstance(parent_summary, dict)
            or not isinstance(parent_build_identity, dict)
            or parent_build_identity != expected_parent_build_identity
            or parent.build_compatibility_key != job.build_compatibility_key
        ):
            raise SubsetReuseUnavailable(
                "parent map preprocessing identity is unavailable"
            )
        cached_source = self._cached_source_for_job(job)
        source_snapshot_sha256 = cached_source.sha256
        calibration = load_building_calibration_window(
            self.paths.osm_extract_root / "conf" / "building_height_rules.yaml"
        )
        scope_plan = self._plan_selected_scope(job, calibration)
        parent_scope_plan = self._plan_selected_scope(parent, calibration)
        try:
            calibration_generation = {
                key: parent_summary["calibration"][key]
                for key in (
                    "calibrationKey",
                    "manifestSha256",
                    "entrySetSha256",
                    "cellCount",
                )
            }
        except (KeyError, TypeError) as exc:
            raise SubsetReuseUnavailable(
                "parent map calibration generation identity is incomplete"
            ) from exc
        try:
            identity = selected_building_identity(
                source_snapshot_sha256=source_snapshot_sha256,
                rules_path=(
                    self.paths.osm_extract_root
                    / "conf"
                    / "building_height_rules.yaml"
                ),
                scope_plan=scope_plan,
                calibration_generation=calibration_generation,
            )
            parent_identity = selected_building_identity(
                source_snapshot_sha256=source_snapshot_sha256,
                rules_path=(
                    self.paths.osm_extract_root
                    / "conf"
                    / "building_height_rules.yaml"
                ),
                scope_plan=parent_scope_plan,
                calibration_generation=calibration_generation,
            )
            parent_closure = dict(parent_summary["closure"])
            parent_closure.pop("relationRetryCount", None)
            parent_metrics = {
                    "mode": "selected",
                    "scope": parent_summary["scope"],
                    "identity": parent_identity,
                    "sourceIndex": parent_summary["sourceIndex"],
                    "closure": parent_closure,
                    "calibration": parent_summary["calibration"],
                }
            if "attemptScope" in parent_summary:
                parent_metrics["attemptScope"] = parent_summary["attemptScope"]
            validated_parent_summary = self._building_preprocessing_summary(
                parent_metrics
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise SubsetReuseUnavailable(
                "parent map preprocessing summary is invalid"
            ) from exc
        if validated_parent_summary != parent_summary:
            raise SubsetReuseUnavailable(
                "parent map preprocessing summary is not canonical"
            )
        parent_expected_keys = reuse_keys(
            parent,
            producer_build_sha256=self.producer_build_sha256,
            producer_image_digest=self.producer_image_digest,
            source_snapshot_sha256=source_snapshot_sha256,
            building_preprocessing_identity=parent_identity,
            preview_sha256=parent_manifest.get("preview", {}).get("sha256"),
        )
        if (
            parent_expected_keys is None
            or parent_expected_keys.exact
            not in {parent.build_cache_key, *parent.build_cache_aliases}
            or parent_expected_keys.compatibility != parent.build_compatibility_key
            or parent_summary.get("identitySha256")
            != parent_identity["identitySha256"]
            or parent_summary.get("scope", {}).get("scopePlanSha256")
            != parent_scope_plan.sha256
        ):
            raise SubsetReuseUnavailable(
                "parent map preprocessing identity does not match its build key"
            )
        expected_keys = reuse_keys(
            job,
            producer_build_sha256=self.producer_build_sha256,
            producer_image_digest=self.producer_image_digest,
            source_snapshot_sha256=source_snapshot_sha256,
            building_preprocessing_identity=identity,
            preview_sha256=self._freeze_preview_identity(job),
        )
        if (
            expected_keys is None
            or expected_keys.exact != job.build_cache_key
            or expected_keys.compatibility != job.build_compatibility_key
        ):
            raise SubsetReuseUnavailable(
                "child map preprocessing identity does not match its build key"
            )
        parent_zip = next(
            (
                artifact
                for artifact in parent.artifacts
                if artifact.format == ZIP_STORED_FORMAT
            ),
            None,
        )
        if parent_zip is None:
            raise SubsetReuseUnavailable("parent ZIP identity is unavailable")
        try:
            dependency_validation_started = time.perf_counter()
            dependency_metrics = self._selected_dependency_metrics(
                cached_source.path,
                source_snapshot_sha256,
                scope_plan,
                calibration_generation,
                on_phase_progress=on_phase_progress,
                cancellation_check=cancellation_check,
            )
            dependency_validation_execution = {
                "durationSeconds": round(
                    time.perf_counter() - dependency_validation_started, 6
                )
            }
            if job.building_preprocessing_runtime is None:
                job.building_preprocessing_runtime = {}
            job.building_preprocessing_runtime["dependencyValidation"] = (
                dependency_validation_execution
            )
        except SubsetReuseUnavailable:
            raise
        except (OSError, RuntimeError, ValueError, KeyError) as exc:
            if cancellation_check is not None and cancellation_check():
                raise
            raise SubsetReuseUnavailable(
                "child map dependency metadata is unavailable"
            ) from exc
        subset_derivation = {
            "baseExactKey": expected_keys.exact,
            "strategy": "subset",
            "parentIdentitySha256": parent_summary["identitySha256"],
            "parentZipSha256": parent_zip.sha256,
        }
        return {
            "subsetBuildCacheAlias": expected_keys.exact,
            "subsetBuildIdentityDerivation": subset_derivation,
            "subsetBuildCacheKey": hashlib.sha256(
                canonical_building_json(subset_derivation)
            ).hexdigest(),
            "buildingPreprocessing": {
                "mode": "selected",
                "scope": scope_plan.summary(),
                "identity": identity,
                **dependency_metrics,
            },
            "buildingReuse": {
                "strategy": "subset",
                "parentMapId": parent.map_id,
                "parentIdentitySha256": parent_summary["identitySha256"],
                "parentZipSha256": parent_zip.sha256,
            },
        }

    def _package_map(
        self,
        job: MapJob,
        pack_root: Path,
        archive_path: Path,
        *,
        artifact_publication_lease=None,
        on_artifact_pending=None,
        build_metrics: dict[str, Any] | None = None,
    ) -> MapBuildResult:
        map_id = job.map_id or stable_map_id(job)
        job.map_id = map_id
        job_dir = archive_path.parent
        packaging_started = time.perf_counter()
        self._resolve_source_preview_geometry(job)
        metrics: dict[str, Any] = dict(build_metrics or {})
        building_preprocessing_summary = self._building_preprocessing_summary(
            metrics.get("buildingPreprocessing")
        )
        manifest = build_manifest(
            job,
            pack_root,
            self._pipeline_metadata(),
            building_stats=metrics.get("buildingBuild"),
            building_preprocessing=building_preprocessing_summary,
        )
        reserved_preview_sha256 = getattr(
            job, "_reserved_preview_sha256", None
        )
        if (
            reserved_preview_sha256 is not None
            and manifest.get("preview", {}).get("sha256")
            != reserved_preview_sha256
        ):
            raise RuntimeError("map preview changed after build identity reservation")
        write_pack_archive(pack_root, manifest, archive_path)
        artifacts: list[ArtifactRecord] = []
        packaging_seconds = time.perf_counter() - packaging_started
        if renderer_format_version(job.request) in {
            LABEL_RENDERER_FORMAT_VERSION,
            BUILDING_RENDERER_FORMAT_VERSION,
        }:
            label_phase_timings = metrics.setdefault("labelPhaseTimings", {})
            if isinstance(label_phase_timings, dict):
                label_phase_timings["labelPackaging"] = packaging_seconds
        if renderer_format_version(job.request) == BUILDING_RENDERER_FORMAT_VERSION:
            building_phase_timings = metrics.setdefault("buildingPhaseTimings", {})
            if isinstance(building_phase_timings, dict):
                building_phase_timings["packaging"] = packaging_seconds
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
            if renderer_format_version(job.request) in {
                LABEL_RENDERER_FORMAT_VERSION,
                BUILDING_RENDERER_FORMAT_VERSION,
            }:
                label_phase_timings = metrics.setdefault("labelPhaseTimings", {})
                if isinstance(label_phase_timings, dict):
                    label_phase_timings["labelSigning"] = stream_build.timings[
                        "signingSeconds"
                    ]
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
            build_cache_key=job.build_cache_key,
            build_cache_aliases=list(job.build_cache_aliases),
            build_identity_derivation=job.build_identity_derivation,
            build_compatibility_key=job.build_compatibility_key,
        )

    @staticmethod
    def _building_preprocessing_summary(value: Any) -> dict[str, Any] | None:
        if not isinstance(value, dict) or value.get("mode") != "selected":
            return None
        try:
            scope = value["scope"]
            identity = value["identity"]
            source_index = value["sourceIndex"]
            closure = value["closure"]
            calibration = value["calibration"]
            identity_body = {
                key: item
                for key, item in identity.items()
                if key != "identitySha256"
            }
            if (
                hashlib.sha256(canonical_building_json(identity_body)).hexdigest()
                != identity["identitySha256"]
                or identity["scope"]["scopePlanSha256"]
                != scope["scopePlanSha256"]
                or identity["sourceSnapshotSha256"]
                != source_index["sourceSnapshotSha256"]
                or identity["sourceSnapshotSha256"]
                != calibration["sourceSnapshotSha256"]
                or identity["sourceIndex"]["schemaVersion"]
                != source_index["schemaVersion"]
                or identity["sourceIndex"]["algorithmVersion"]
                != source_index["algorithmVersion"]
                or identity["calibration"]["calibrationKey"]
                != calibration["calibrationKey"]
                or identity["calibration"]["rulesSha256"]
                != calibration["rulesSha256"]
                or identity["calibration"]["manifestSha256"]
                != calibration["manifestSha256"]
                or identity["calibration"]["entrySetSha256"]
                != calibration["entrySetSha256"]
                or identity["calibration"]["generationCellCount"]
                != calibration["cellCount"]
            ):
                raise ValueError(
                    "selected building preprocessing identity is inconsistent"
                )
            summary = {
                "schemaVersion": 1,
                "identitySha256": identity["identitySha256"],
                "sourceSnapshotSha256": identity["sourceSnapshotSha256"],
                "scope": {
                    key: scope[key]
                    for key in (
                        "scopePolicyVersion",
                        "scopePlanSha256",
                        "requestedApproximateAreaM2",
                        "outputAreaM2",
                        "sourceAreaM2",
                        "sourceToOutputAreaBasisPoints",
                        "outputBlockCount",
                        "calibrationCellCount",
                        "calibrationSampleCellCount",
                        "geometryBufferMeters",
                        "sourceBoundsE7",
                    )
                },
                "sourceIndex": {
                    key: source_index[key]
                    for key in (
                        "indexKey",
                        "sourceSnapshotSha256",
                        "databaseSha256",
                        "schemaVersion",
                        "algorithmVersion",
                        "nodeCount",
                        "wayCount",
                        "relationCount",
                        "relationMemberCount",
                    )
                },
                "closure": {
                    key: closure[key]
                    for key in (
                        "closurePlanSha256",
                        "candidateCount",
                        "relationCount",
                        "wayCount",
                        "nodeCount",
                        "calibrationCellCount",
                    )
                },
                "calibration": {
                    key: calibration[key]
                    for key in (
                        "calibrationKey",
                        "sourceSnapshotSha256",
                        "rulesSha256",
                        "manifestSha256",
                        "entrySetSha256",
                        "cellCount",
                        "cellsRequested",
                        "cellsHits",
                        "cellsMisses",
                        "cellsRebuilt",
                    )
                },
            }
            if "attemptScope" in value:
                attempt_scope = value["attemptScope"]
                summary["attemptScope"] = {
                    key: attempt_scope[key]
                    for key in (
                        "scopePlanSha256",
                        "sourceAreaM2",
                        "sourceToOutputAreaBasisPoints",
                        "geometryBufferMeters",
                        "sourceBoundsE7",
                        "closurePlanSha256",
                    )
                }
        except (KeyError, TypeError) as exc:
            raise ValueError("selected building preprocessing metrics are incomplete") from exc
        digest_paths = (
            summary["identitySha256"],
            summary["sourceSnapshotSha256"],
            summary["scope"]["scopePlanSha256"],
            summary["sourceIndex"]["indexKey"],
            summary["sourceIndex"]["sourceSnapshotSha256"],
            summary["sourceIndex"]["databaseSha256"],
            summary["closure"]["closurePlanSha256"],
            summary["calibration"]["calibrationKey"],
            summary["calibration"]["sourceSnapshotSha256"],
            summary["calibration"]["rulesSha256"],
            summary["calibration"]["manifestSha256"],
            summary["calibration"]["entrySetSha256"],
        )
        if "attemptScope" in summary:
            digest_paths += (
                summary["attemptScope"]["scopePlanSha256"],
                summary["attemptScope"]["closurePlanSha256"],
            )
        if any(not re.fullmatch(r"[0-9a-f]{64}", str(item)) for item in digest_paths):
            raise ValueError("selected building preprocessing digest is invalid")
        counts = (
            summary["scope"]["requestedApproximateAreaM2"],
            summary["scope"]["outputAreaM2"],
            summary["scope"]["sourceAreaM2"],
            summary["scope"]["sourceToOutputAreaBasisPoints"],
            summary["scope"]["outputBlockCount"],
            summary["scope"]["calibrationCellCount"],
            summary["scope"]["calibrationSampleCellCount"],
            summary["scope"]["geometryBufferMeters"],
            summary["sourceIndex"]["nodeCount"],
            summary["sourceIndex"]["wayCount"],
            summary["sourceIndex"]["relationCount"],
            summary["sourceIndex"]["relationMemberCount"],
            summary["closure"]["candidateCount"],
            summary["closure"]["relationCount"],
            summary["closure"]["wayCount"],
            summary["closure"]["nodeCount"],
            summary["closure"]["calibrationCellCount"],
            summary["calibration"]["cellCount"],
            summary["calibration"]["cellsRequested"],
            summary["calibration"]["cellsHits"],
            summary["calibration"]["cellsMisses"],
            summary["calibration"]["cellsRebuilt"],
        )
        if "attemptScope" in summary:
            counts += (
                summary["attemptScope"]["sourceAreaM2"],
                summary["attemptScope"]["sourceToOutputAreaBasisPoints"],
                summary["attemptScope"]["geometryBufferMeters"],
            )
        if any(
            isinstance(item, bool) or not isinstance(item, int) or item < 0
            for item in counts
        ):
            raise ValueError("selected building preprocessing count is invalid")
        if (
            summary["scope"]["outputAreaM2"] <= 0
            or summary["scope"]["sourceAreaM2"] <= 0
            or summary["scope"]["outputBlockCount"] <= 0
            or summary["calibration"]["cellCount"] <= 0
            or summary["calibration"]["cellsHits"]
            + summary["calibration"]["cellsMisses"]
            + summary["calibration"]["cellsRebuilt"]
            != summary["calibration"]["cellsRequested"]
        ):
            raise ValueError("selected building preprocessing totals are invalid")
        _validate_integer_only_summary(summary)
        return summary

    def published_archive_path(self, map_id: str, job_id: str) -> Path:
        return self.paths.pack_root / map_id / f"{job_id}.zip"

    def _resolve_source_preview_geometry(self, job: MapJob) -> None:
        resolver = self.source_preview_geometry_resolver
        if (
            getattr(job, "_source_preview_resolution_frozen", False)
            or job.source_region.preview_geometry is not None
            or resolver is None
        ):
            job._source_preview_resolution_frozen = True
            return
        try:
            geometry = resolver(job.source_region)
        except SourceResolutionError:
            geometry = None
        finally:
            job._source_preview_resolution_frozen = True
        if isinstance(geometry, dict) and geometry:
            job.source_region = replace(job.source_region, preview_geometry=geometry)

    def _freeze_preview_identity(self, job: MapJob) -> str:
        preview_sha256 = hashlib.sha256(
            render_boundary_preview(
                job.source_region.preview_geometry or job.geometry.geometry,
                job.geometry.bounds,
            )
        ).hexdigest()
        previous = getattr(job, "_reserved_preview_sha256", None)
        if previous is None:
            job._reserved_preview_sha256 = preview_sha256
        elif previous != preview_sha256:
            raise RuntimeError("map preview identity changed after reservation")
        return preview_sha256

    def _source_pbf_path(self, job: MapJob) -> Path:
        return self._cached_source_for_job(job).path

    def _cached_source_for_job(self, job: MapJob):
        leased = getattr(job, "_leased_cached_source", None)
        cached = leased if leased is not None else self.source_cache.ensure(job.source_region)
        frozen = job.building_preprocessing_inputs
        if (
            frozen is not None
            and frozen.get("sourceSnapshotSha256") != cached.sha256
        ):
            raise BuildingScopeError(
                "building_source_snapshot_changed",
                "frozen source snapshot changed before selected-area build",
            )
        return cached

    def _run_command(
        self,
        args: list[str],
        *,
        cwd: Path | None = None,
        cancellation_check=None,
    ) -> str:
        kwargs: dict[str, Any] = {"cwd": cwd} if cwd is not None else {}
        if cancellation_check is not None and isinstance(
            self.runner, CommandRunner
        ):
            kwargs["cancellation_check"] = cancellation_check
        return self.runner.run(args, **kwargs)

    def _extract_pbf(
        self,
        job: MapJob,
        source_pbf: Path,
        clipped_pbf: Path,
        *,
        bounds=None,
        force_bounds: bool = False,
        scope_plan: ScopePlan | None = None,
        source_snapshot_sha256: str | None = None,
        cancellation_check=None,
    ) -> None:
        bounds = bounds or job.geometry.bounds
        extraction_option = (
            ["--option=types=multipolygon,building"]
            if renderer_format_version(job.request) == BUILDING_RENDERER_FORMAT_VERSION
            else []
        )
        if scope_plan is not None:
            if source_snapshot_sha256 is None:
                raise ValueError("plan-aware extraction requires a source identity")
            if sha256_file(source_pbf) != source_snapshot_sha256:
                raise BuildingScopeError(
                    "building_source_snapshot_changed",
                    "source snapshot changed before selected-area extraction",
                )
            part_root = clipped_pbf.parent / "source-scope-parts"
            if part_root.exists():
                shutil.rmtree(part_root)
            part_root.mkdir()
            part_paths = []
            extracts = []
            for index, (min_x, min_y, max_x, max_y) in enumerate(
                scope_plan.document["sourceScope"]["rectanglesMeters"]
            ):
                name = f"part-{index:05d}.osm.pbf"
                part_paths.append(part_root / name)
                extracts.append(
                    {
                        "output": name,
                        "output_format": "pbf",
                        "bbox": [
                            x_to_lon(min_x),
                            y_to_lat(min_y),
                            x_to_lon(max_x),
                            y_to_lat(max_y),
                        ],
                    }
                )
            config_path = clipped_pbf.parent / "source-scope-extract.json"
            config_path.write_text(
                json.dumps(
                    {
                        "directory": str(part_root),
                        "extracts": extracts,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                encoding="utf-8",
            )
            args = [
                "osmium", "extract", "--strategy=smart", *extraction_option,
                "--config", str(config_path), str(source_pbf), "--overwrite",
            ]
        else:
            args = [
                "osmium", "extract", "--strategy=smart", *extraction_option,
                "-b",
                f"{bounds.min_lon},{bounds.min_lat},{bounds.max_lon},{bounds.max_lat}",
                str(source_pbf), "-o", str(clipped_pbf), "--overwrite",
            ]
        if (
            scope_plan is None
            and not force_bounds
            and job.geometry.geometry
            and job.geometry.mode.value == "custom_polygon"
        ):
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
        self._run_command(args, cancellation_check=cancellation_check)
        if scope_plan is not None:
            self._run_command(
                [
                    "osmium",
                    "merge",
                    *(str(path) for path in part_paths),
                    "-o",
                    str(clipped_pbf),
                    "--overwrite",
                ],
                cancellation_check=cancellation_check,
            )
            if sha256_file(source_pbf) != source_snapshot_sha256:
                clipped_pbf.unlink(missing_ok=True)
                raise BuildingScopeError(
                    "building_source_snapshot_changed",
                    "source snapshot changed during selected-area extraction",
                )

    def _run_preprocessing_command(
        self,
        args: list[str],
        *,
        cwd: Path,
        on_phase_progress,
        default_unit: str,
        total_blocks: int,
        timings: dict[str, float] | None = None,
        cancellation_check=None,
    ) -> str:
        command_started = time.perf_counter()
        self._emit_phase_progress(
            on_phase_progress,
            unit=default_unit,
            completed=0,
            total=1,
            total_blocks=total_blocks,
            indeterminate=False,
        )

        def handle_output(line: str) -> None:
            progress = parse_building_preprocess_progress(line)
            if progress is None:
                return
            self._emit_phase_progress(
                on_phase_progress,
                unit=progress["unit"],
                completed=progress["completed"],
                total=progress["total"],
                total_blocks=total_blocks,
                indeterminate=progress["indeterminate"],
            )

        try:
            if (
                (on_phase_progress is not None or cancellation_check is not None)
                and hasattr(self.runner, "run_streaming")
            ):
                streaming_kwargs = {
                    "cwd": cwd,
                    "on_output": handle_output,
                }
                if cancellation_check is not None:
                    streaming_kwargs["cancellation_check"] = cancellation_check
                output = self.runner.run_streaming(args, **streaming_kwargs)
            else:
                output = self.runner.run(args, cwd=cwd)
                if on_phase_progress is not None:
                    for line in output.splitlines():
                        handle_output(line)
        except subprocess.CalledProcessError as exc:
            command_output = "\n".join(
                value
                for value in (
                    getattr(exc, "stdout", None),
                    getattr(exc, "stderr", None),
                    getattr(exc, "output", None),
                )
                if isinstance(value, str)
            )
            failure = parse_building_failure(command_output)
            if failure is not None:
                raise BuildingScopeError(failure["code"], failure["message"]) from exc
            default_code = (
                "building_calibration_unavailable"
                if default_unit.startswith("calibration")
                else "building_relation_incomplete"
            )
            raise BuildingScopeError(
                default_code,
                f"{default_unit} preprocessing failed",
            ) from exc
        except RuntimeError:
            if cancellation_check is not None and cancellation_check():
                self._cleanup_cancelled_source_index(
                    args,
                    cwd=cwd,
                    default_unit=default_unit,
                )
            raise
        self._emit_phase_progress(
            on_phase_progress,
            unit=default_unit,
            completed=1,
            total=1,
            total_blocks=total_blocks,
            indeterminate=False,
        )
        if timings is not None:
            timings[default_unit] = timings.get(default_unit, 0.0) + (
                time.perf_counter() - command_started
            )
        return output

    def _cleanup_cancelled_source_index(
        self,
        args: list[str],
        *,
        cwd: Path,
        default_unit: str,
    ) -> None:
        """Remove unpublished persistent scan files after a killed indexer."""
        if default_unit != "source_index":
            return
        try:
            cache_root = args[args.index("--cache-root") + 1]
            source_sha256 = args[args.index("--source-sha256") + 1]
        except (ValueError, IndexError):
            return
        cleanup_script = cwd / "build_building_source_index.py"
        if not cleanup_script.is_file():
            return
        try:
            CommandRunner().run(
                [
                    sys.executable,
                    str(cleanup_script),
                    "--source-sha256",
                    source_sha256,
                    "--cache-root",
                    cache_root,
                    "--cleanup-unpublished",
                    "--lock-timeout-seconds",
                    "5",
                ],
                cwd=cwd,
            )
        except (OSError, RuntimeError, subprocess.CalledProcessError):
            # The next builder also removes stale scans under the same lock.
            pass

    def _ensure_selected_calibration_generation(
        self,
        source_pbf: Path,
        source_snapshot_sha256: str,
        scope_plan: ScopePlan,
        *,
        on_phase_progress=None,
        execution_sink: dict[str, Any] | None = None,
        cancellation_check=None,
    ) -> tuple[Path, dict[str, Any]]:
        generation_started = time.perf_counter()
        self.paths.work_root.mkdir(parents=True, exist_ok=True)
        scripts_root = self.paths.osm_extract_root / "scripts"
        calibration_identity = selected_calibration_identity(
            source_snapshot_sha256=source_snapshot_sha256,
            rules_path=(
                self.paths.osm_extract_root / "conf" / "building_height_rules.yaml"
            ),
            scope_plan=scope_plan,
        )
        sealed_manifest_path = calibration_generation_manifest_path(
            self.paths.building_cache_root,
            calibration_identity,
        )
        try:
            generation = calibration_generation_from_manifest(
                sealed_manifest_path,
                source_snapshot_sha256=source_snapshot_sha256,
                calibration_key=calibration_identity["calibrationKey"],
                calibration_identity=calibration_identity,
            )
            self._emit_phase_progress(
                on_phase_progress,
                unit="calibration_cache",
                completed=1,
                total=1,
                total_blocks=len(scope_plan.output_blocks),
                indeterminate=False,
            )
            if execution_sink is not None:
                execution_sink.update(
                    {
                        "cacheOutcome": "hit",
                        "cellsRequested": generation["cellCount"],
                        "cellsHits": generation["cellCount"],
                        "cellsMisses": 0,
                        "cellsRebuilt": 0,
                        "durationSeconds": round(
                            time.perf_counter() - generation_started, 6
                        ),
                    }
                )
            return sealed_manifest_path, generation
        except ValueError:
            pass
        with tempfile.TemporaryDirectory(
            prefix="building-calibration-generation-",
            dir=self.paths.work_root,
        ) as temporary:
            temporary_root = Path(temporary)
            scope_path = temporary_root / "scope-plan.json"
            result_path = temporary_root / "calibration-result.json"
            scope_plan.write(scope_path)
            command_timings: dict[str, float] = {}
            self._run_preprocessing_command(
                [
                    sys.executable,
                    str(scripts_root / "build_building_calibration.py"),
                    "--source-pbf",
                    str(source_pbf),
                    "--source-sha256",
                    source_snapshot_sha256,
                    "--rules",
                    str(
                        self.paths.osm_extract_root
                        / "conf"
                        / "building_height_rules.yaml"
                    ),
                    "--scope-plan",
                    str(scope_path),
                    "--cache-root",
                    str(self.paths.building_cache_root),
                    "--result-json",
                    str(result_path),
                    "--full-precompute",
                ],
                cwd=scripts_root,
                on_phase_progress=on_phase_progress,
                default_unit="calibration_cells",
                total_blocks=len(scope_plan.output_blocks),
                timings=command_timings,
                cancellation_check=cancellation_check,
            )
            try:
                result = json.loads(result_path.read_bytes())
                manifest_path = Path(result["manifestPath"])
                generation = calibration_generation_from_manifest(
                    manifest_path,
                    source_snapshot_sha256=source_snapshot_sha256,
                    calibration_key=result.get("calibrationKey"),
                    calibration_identity=calibration_identity,
                )
            except (OSError, TypeError, ValueError, KeyError) as exc:
                raise BuildingScopeError(
                    "building_calibration_unavailable",
                    "sealed building calibration generation is unavailable",
                ) from exc
            if execution_sink is not None:
                public_result = {
                    key: value
                    for key, value in result.items()
                    if key != "manifestPath"
                }
                execution_sink.update(public_result)
                execution_sink["cacheOutcome"] = (
                    "rebuilt"
                    if public_result.get("cellsMisses", 0)
                    or public_result.get("cellsRebuilt", 0)
                    else "filled_by_peer"
                )
                execution_sink["commandSeconds"] = round(
                    command_timings.get("calibration_cells", 0.0), 6
                )
                execution_sink["durationSeconds"] = round(
                    time.perf_counter() - generation_started, 6
                )
        return manifest_path, generation

    def _prepare_selected_building_inputs(
        self,
        source_pbf: Path,
        clipped_pbf: Path,
        source_snapshot_sha256: str,
        scope_plan_path: Path,
        job_dir: Path,
        *,
        expected_calibration_generation: dict[str, Any],
        on_phase_progress=None,
        cancellation_check=None,
    ) -> tuple[Path, Path, dict[str, Any]]:
        scripts_root = self.paths.osm_extract_root / "scripts"
        cache_root = self.paths.building_cache_root
        source_index_result = job_dir / "source-index-result.json"
        calibration_result = job_dir / "calibration-result.json"
        closure_plan = job_dir / "building-closure-plan.json"
        closure_ids = job_dir / "building-closure-ids.txt"
        scope_document = json.loads(scope_plan_path.read_bytes())
        total_blocks = len(scope_document["outputBlocks"])
        preprocessing_timings: dict[str, float] = {}
        self._run_preprocessing_command(
            [
                sys.executable,
                str(scripts_root / "build_building_source_index.py"),
                "--source-pbf", str(source_pbf),
                "--source-sha256", source_snapshot_sha256,
                "--cache-root", str(cache_root),
                "--result-json", str(source_index_result),
            ],
            cwd=scripts_root,
            on_phase_progress=on_phase_progress,
            default_unit="source_index",
            total_blocks=total_blocks,
            timings=preprocessing_timings,
            cancellation_check=cancellation_check,
        )
        try:
            source_index = json.loads(source_index_result.read_bytes())
            source_index_manifest = Path(source_index.pop("manifestPath"))
        except (OSError, TypeError, ValueError, KeyError) as exc:
            raise BuildingScopeError(
                "building_relation_incomplete",
                "building source index did not publish valid metadata",
            ) from exc
        if (
            source_index.get("sourceSnapshotSha256") != source_snapshot_sha256
            or not source_index_manifest.is_file()
        ):
            raise BuildingScopeError(
                "building_relation_incomplete",
                "building source index identity is invalid",
            )
        self._run_preprocessing_command(
            [
                sys.executable,
                str(scripts_root / "build_building_closure.py"),
                "--source-index-manifest", str(source_index_manifest),
                "--scope-plan", str(scope_plan_path),
                "--closure-plan", str(closure_plan),
                "--ids-output", str(closure_ids),
            ],
            cwd=scripts_root,
            on_phase_progress=on_phase_progress,
            default_unit="relation_closure",
            total_blocks=total_blocks,
            timings=preprocessing_timings,
            cancellation_check=cancellation_check,
        )
        try:
            closure = json.loads(closure_plan.read_bytes())
            required_count = sum(
                len(closure[key])
                for key in (
                    "requiredRelationKeys", "requiredWayKeys", "requiredNodeKeys"
                )
            )
        except (OSError, TypeError, ValueError, KeyError) as exc:
            raise BuildingScopeError(
                "building_relation_incomplete",
                "building closure did not publish valid metadata",
            ) from exc
        if (
            closure.get("sourceSnapshotSha256") != source_snapshot_sha256
            or not closure_ids.is_file()
        ):
            raise BuildingScopeError(
                "building_relation_incomplete",
                "building closure identity is invalid",
            )
        if required_count:
            self._rehydrate_building_closure(
                source_pbf,
                clipped_pbf,
                closure_ids,
                source_snapshot_sha256,
                job_dir,
                cancellation_check=cancellation_check,
            )
        self._run_preprocessing_command(
            [
                sys.executable,
                str(scripts_root / "build_building_calibration.py"),
                "--source-pbf", str(source_pbf),
                "--source-sha256", source_snapshot_sha256,
                "--rules",
                str(self.paths.osm_extract_root / "conf" / "building_height_rules.yaml"),
                "--scope-plan", str(scope_plan_path),
                "--closure-plan", str(closure_plan),
                "--cache-root", str(cache_root),
                "--result-json", str(calibration_result),
                "--full-precompute",
            ],
            cwd=scripts_root,
            on_phase_progress=on_phase_progress,
            default_unit="calibration_cells",
            total_blocks=total_blocks,
            timings=preprocessing_timings,
            cancellation_check=cancellation_check,
        )
        try:
            calibration = json.loads(calibration_result.read_bytes())
            calibration_manifest = Path(calibration.pop("manifestPath"))
            calibration_generation = calibration_generation_from_manifest(
                calibration_manifest,
                source_snapshot_sha256=source_snapshot_sha256,
                calibration_key=calibration.get("calibrationKey"),
            )
        except (OSError, TypeError, ValueError, KeyError) as exc:
            raise BuildingScopeError(
                "building_calibration_unavailable",
                "building calibration did not publish valid result metadata",
            ) from exc
        if (
            source_index.get("sourceSnapshotSha256") != source_snapshot_sha256
            or calibration.get("sourceSnapshotSha256") != source_snapshot_sha256
            or not source_index_manifest.is_file()
            or not calibration_manifest.is_file()
            or calibration_generation != expected_calibration_generation
        ):
            raise BuildingScopeError(
                "building_calibration_unavailable",
                "building calibration result identity is invalid",
            )
        execution = dict(calibration)
        scope_document.pop("scopePlanSha256", None)
        requested_cells = {
            tuple(cell) for cell in scope_document["calibration"]["sampleCells"]
        }
        requested_cells.update(
            tuple(cell) for cell in closure.get("calibrationSampleCells", [])
        )
        calibration = {
            "sourceSnapshotSha256": source_snapshot_sha256,
            "rulesSha256": execution["rulesSha256"],
            **calibration_generation,
            "cellsRequested": len(requested_cells),
            "cellsHits": len(requested_cells),
            "cellsMisses": 0,
            "cellsRebuilt": 0,
        }
        return calibration_manifest, source_index_manifest, {
            "sourceBytes": source_pbf.stat().st_size,
            "sourceIndex": source_index,
            "closure": {
                "closurePlanSha256": closure["closurePlanSha256"],
                "candidateCount": len(closure["candidateKeys"]),
                "relationCount": len(closure["requiredRelationKeys"]),
                "wayCount": len(closure["requiredWayKeys"]),
                "nodeCount": len(closure["requiredNodeKeys"]),
                "calibrationCellCount": len(closure["calibrationSampleCells"]),
            },
            "calibration": calibration,
            "calibrationExecution": execution,
            "phaseTimings": {
                key: round(value, 6)
                for key, value in preprocessing_timings.items()
            },
        }

    def _selected_dependency_metrics(
        self,
        source_pbf: Path,
        source_snapshot_sha256: str,
        scope_plan: ScopePlan,
        calibration_generation: dict[str, Any],
        *,
        on_phase_progress=None,
        cancellation_check=None,
    ) -> dict[str, Any]:
        self.paths.work_root.mkdir(parents=True, exist_ok=True)
        scripts_root = self.paths.osm_extract_root / "scripts"
        with tempfile.TemporaryDirectory(
            prefix="building-dependency-metadata-",
            dir=self.paths.work_root,
        ) as temporary:
            root = Path(temporary)
            scope_path = root / "scope-plan.json"
            source_index_result = root / "source-index-result.json"
            closure_plan = root / "building-closure-plan.json"
            closure_ids = root / "building-closure-ids.txt"
            scope_plan.write(scope_path)
            self._run_preprocessing_command(
                [
                    sys.executable,
                    str(scripts_root / "build_building_source_index.py"),
                    "--source-pbf",
                    str(source_pbf),
                    "--source-sha256",
                    source_snapshot_sha256,
                    "--cache-root",
                    str(self.paths.building_cache_root),
                    "--result-json",
                    str(source_index_result),
                ],
                cwd=scripts_root,
                on_phase_progress=on_phase_progress,
                default_unit="source_index",
                total_blocks=len(scope_plan.output_blocks),
                cancellation_check=cancellation_check,
            )
            try:
                source_index = json.loads(source_index_result.read_bytes())
                source_index_manifest = Path(source_index.pop("manifestPath"))
            except (OSError, TypeError, ValueError, KeyError) as exc:
                raise SubsetReuseUnavailable(
                    "building source index metadata is unavailable"
                ) from exc
            self._run_preprocessing_command(
                [
                    sys.executable,
                    str(scripts_root / "build_building_closure.py"),
                    "--source-index-manifest",
                    str(source_index_manifest),
                    "--scope-plan",
                    str(scope_path),
                    "--closure-plan",
                    str(closure_plan),
                    "--ids-output",
                    str(closure_ids),
                ],
                cwd=scripts_root,
                on_phase_progress=on_phase_progress,
                default_unit="relation_closure",
                total_blocks=len(scope_plan.output_blocks),
                cancellation_check=cancellation_check,
            )
            try:
                closure = json.loads(closure_plan.read_bytes())
            except (OSError, TypeError, ValueError) as exc:
                raise SubsetReuseUnavailable(
                    "building closure metadata is unavailable"
                ) from exc
        calibration_identity = selected_calibration_identity(
            source_snapshot_sha256=source_snapshot_sha256,
            rules_path=(
                self.paths.osm_extract_root / "conf" / "building_height_rules.yaml"
            ),
            scope_plan=scope_plan,
        )
        requested_cells = set(scope_plan.calibration_sample_cells)
        requested_cells.update(
            tuple(cell) for cell in closure.get("calibrationSampleCells", [])
        )
        return {
            "sourceIndex": source_index,
            "closure": {
                "closurePlanSha256": closure["closurePlanSha256"],
                "candidateCount": len(closure["candidateKeys"]),
                "relationCount": len(closure["requiredRelationKeys"]),
                "wayCount": len(closure["requiredWayKeys"]),
                "nodeCount": len(closure["requiredNodeKeys"]),
                "calibrationCellCount": len(closure["calibrationSampleCells"]),
            },
            "calibration": {
                "sourceSnapshotSha256": source_snapshot_sha256,
                "rulesSha256": calibration_identity["rulesSha256"],
                **calibration_generation,
                "cellsRequested": len(requested_cells),
                "cellsHits": len(requested_cells),
                "cellsMisses": 0,
                "cellsRebuilt": 0,
            },
        }

    def _rehydrate_building_closure(
        self,
        source_pbf: Path,
        clipped_pbf: Path,
        closure_ids: Path,
        source_snapshot_sha256: str,
        job_dir: Path,
        *,
        cancellation_check=None,
    ) -> None:
        if sha256_file(source_pbf) != source_snapshot_sha256:
            raise BuildingScopeError(
                "building_source_snapshot_changed",
                "source snapshot changed before building closure rehydration",
            )
        closure_pbf = job_dir / "building-closure.osm.pbf"
        merged_pbf = job_dir / "clipped-with-building-closure.osm.pbf"
        self._run_command(
            [
                "osmium", "getid", "--add-referenced", str(source_pbf),
                "--id-file", str(closure_ids), "-o", str(closure_pbf), "--overwrite",
            ],
            cancellation_check=cancellation_check,
        )
        self._run_command(
            [
                "osmium", "merge", str(clipped_pbf), str(closure_pbf),
                "-o", str(merged_pbf), "--overwrite",
            ],
            cancellation_check=cancellation_check,
        )
        if sha256_file(source_pbf) != source_snapshot_sha256:
            merged_pbf.unlink(missing_ok=True)
            raise BuildingScopeError(
                "building_source_snapshot_changed",
                "source snapshot changed during building closure rehydration",
            )
        os.replace(merged_pbf, clipped_pbf)

    def _convert_to_geojson(
        self,
        job: MapJob,
        clipped_pbf: Path,
        geojson_prefix: Path,
        *,
        bounds=None,
        source_index_manifest: Path | None = None,
        scope_plan_path: Path | None = None,
        relation_retry_count: int = 0,
        cancellation_check=None,
    ) -> None:
        bounds = bounds or job.geometry.bounds
        script = self.paths.osm_extract_root / "scripts" / "pbf_to_geojson.sh"
        args = [
                "bash",
                str(script),
                str(bounds.min_lon),
                str(bounds.min_lat),
                str(bounds.max_lon),
                str(bounds.max_lat),
                str(clipped_pbf),
                str(geojson_prefix),
            ]
        if source_index_manifest is not None:
            if scope_plan_path is None:
                raise ValueError("source index audit requires a scope plan")
            if relation_retry_count < 0:
                raise ValueError("relation retry count cannot be negative")
            args.extend(
                [
                    str(source_index_manifest),
                    str(scope_plan_path),
                    str(relation_retry_count),
                ]
            )
        self._run_command(
            args,
            cwd=self.paths.osm_extract_root / "scripts",
            cancellation_check=cancellation_check,
        )

    def _extract_features(
        self,
        job: MapJob,
        geojson_prefix: Path,
        raw_output_dir: Path,
        *,
        bounds=None,
        on_progress=None,
        scope_plan_path: Path | None = None,
        calibration_manifest: Path | None = None,
        calibration_source_sha256: str | None = None,
        on_phase_progress=None,
        planned_scope_marker: dict[str, Any] | None = None,
        cancellation_check=None,
    ) -> dict[str, Any]:
        bounds = bounds or job.geometry.bounds
        script = self.paths.osm_extract_root / "scripts" / "extract_features.py"
        args = [
            sys.executable,
            str(script),
            str(bounds.min_lon),
            str(bounds.min_lat),
            str(bounds.max_lon),
            str(bounds.max_lat),
            str(geojson_prefix),
            str(raw_output_dir),
        ]
        format_version = renderer_format_version(job.request)
        args.extend(["--renderer-format", str(format_version)])
        if format_version in {
            LABEL_RENDERER_FORMAT_VERSION,
            BUILDING_RENDERER_FORMAT_VERSION,
        }:
            labels = job.request["labels"]
            for language in labels["preferredLanguages"]:
                args.extend(["--preferred-language", language])
            args.extend(
                ["--international-fallback", labels["internationalFallback"]]
            )
        if scope_plan_path is not None:
            args.extend(["--scope-plan", str(scope_plan_path)])
            if planned_scope_marker is not None:
                args.append("--suppress-scope-marker")
        if calibration_manifest is not None:
            args.extend(["--calibration-manifest", str(calibration_manifest)])
            args.extend(
                ["--calibration-source-sha256", str(calibration_source_sha256)]
            )
        if (
            format_version == BUILDING_RENDERER_FORMAT_VERSION
            and job.geometry.geometry is not None
            and job.geometry.mode.value in {"custom_polygon", "route_corridor"}
        ):
            selection_path = geojson_prefix.parent / "feature-selection.geojson"
            selection_path.write_text(
                json.dumps(
                    job.geometry.geometry,
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                encoding="utf-8",
            )
            args.extend(["--selection-geometry", str(selection_path)])
            if job.geometry.mode.value == "route_corridor":
                args.extend(
                    ["--selection-buffer-m", str(job.geometry.corridor_width_m)]
                )
        progress_coalescer = ProgressCoalescer()
        label_stats: dict[str, Any] | None = None
        building_stats: dict[str, Any] | None = None
        building_scope: dict[str, Any] | None = None

        def handle_output(line: str) -> None:
            nonlocal label_stats, building_stats, building_scope
            preprocess_progress = parse_building_preprocess_progress(line)
            if preprocess_progress is not None:
                self._emit_phase_progress(
                    on_phase_progress,
                    phase="building_preprocessing",
                    unit=preprocess_progress["unit"],
                    completed=preprocess_progress["completed"],
                    total=preprocess_progress["total"],
                    total_blocks=(
                        planned_scope_marker.get("outputBlockCount")
                        if isinstance(planned_scope_marker, dict)
                        else None
                    ),
                    indeterminate=preprocess_progress["indeterminate"],
                )
            progress = parse_map_progress(line)
            if progress is not None and progress_coalescer.should_emit(*progress):
                self._emit_phase_progress(
                    on_phase_progress,
                    phase="block_encoding",
                    unit="blocks",
                    completed=progress[0],
                    total=progress[1],
                    total_blocks=progress[1],
                    indeterminate=False,
                )
                if on_progress:
                    on_progress(*progress)
            parsed_label_stats = parse_label_stats(line)
            if parsed_label_stats is not None:
                label_stats = parsed_label_stats
            parsed_building_stats = parse_building_stats(line)
            if parsed_building_stats is not None:
                building_stats = parsed_building_stats
            parsed_building_scope = parse_building_scope(line)
            if parsed_building_scope is not None:
                if building_scope is not None:
                    raise RuntimeError("building-aware extraction emitted BUILDING_SCOPE more than once")
                building_scope = parsed_building_scope

        if (
            on_progress or on_phase_progress or cancellation_check is not None
        ) and hasattr(self.runner, "run_streaming"):
            streaming_kwargs = {
                "cwd": self.paths.osm_extract_root / "scripts",
                "on_output": handle_output,
            }
            if cancellation_check is not None:
                streaming_kwargs["cancellation_check"] = cancellation_check
            self.runner.run_streaming(args, **streaming_kwargs)
            return self._build_metrics(
                format_version,
                label_stats,
                building_stats,
                planned_scope_marker or building_scope,
                require_building_scope=(
                    scope_plan_path is not None and planned_scope_marker is None
                ),
            )

        output = self.runner.run(args, cwd=self.paths.osm_extract_root / "scripts")
        for line in output.splitlines():
            handle_output(line)
        return self._build_metrics(
            format_version,
            label_stats,
            building_stats,
            planned_scope_marker or building_scope,
            require_building_scope=(
                scope_plan_path is not None and planned_scope_marker is None
            ),
        )

    @staticmethod
    def _build_metrics(
        format_version: int,
        stats: dict[str, Any] | None,
        building_stats: dict[str, Any] | None,
        building_scope: dict[str, Any] | None = None,
        *,
        require_building_scope: bool = False,
    ) -> dict[str, Any]:
        if format_version not in {
            LABEL_RENDERER_FORMAT_VERSION,
            BUILDING_RENDERER_FORMAT_VERSION,
        }:
            return {}
        if stats is None:
            raise RuntimeError("label-aware extraction did not emit LABEL_STATS")
        phase_timings = stats.pop("phaseTimings", {})
        if not isinstance(phase_timings, dict) or not all(
            isinstance(key, str)
            and isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(float(value))
            and value >= 0
            for key, value in phase_timings.items()
        ):
            raise RuntimeError("label-aware extraction emitted invalid phase timings")
        result = {
            "labelBuild": stats,
            "labelPhaseTimings": phase_timings,
        }
        if format_version == BUILDING_RENDERER_FORMAT_VERSION:
            if building_stats is None:
                raise RuntimeError("building-aware extraction did not emit BUILDING_STATS")
            building_phase_timings = building_stats.pop("phaseTimings", {})
            if not isinstance(building_phase_timings, dict) or not all(
                isinstance(key, str)
                and isinstance(value, (int, float))
                and not isinstance(value, bool)
                and math.isfinite(float(value))
                and value >= 0
                for key, value in building_phase_timings.items()
            ):
                raise RuntimeError(
                    "building-aware extraction emitted invalid phase timings"
                )
            result["buildingBuild"] = building_stats
            result["buildingScriptPhaseTimings"] = building_phase_timings
            if require_building_scope and building_scope is None:
                raise RuntimeError("selected building extraction did not emit BUILDING_SCOPE")
            if building_scope is not None:
                result["buildingScope"] = building_scope
        return result

    def _stage_subset_pack(
        self,
        child: MapJob,
        parent: MapJob,
        pack_root: Path,
    ) -> dict[str, Any]:
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
        if (
            self.building_scope_mode == "selected"
            and renderer_format_version(child.request)
            == BUILDING_RENDERER_FORMAT_VERSION
        ):
            calibration = load_building_calibration_window(
                self.paths.osm_extract_root / "conf" / "building_height_rules.yaml"
            )
            required = set(
                self._plan_selected_scope(child, calibration).output_blocks
            )
        else:
            required = required_blocks(child.geometry.bounds)
        child_map_id = child.map_id or stable_map_id(child)
        copied_fmb_blocks = set()
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
                preview = manifest.get("preview")
                if (
                    not isinstance(preview, dict)
                    or preview.get("path") != "preview.png"
                    or isinstance(preview.get("bytes"), bool)
                    or not isinstance(preview.get("bytes"), int)
                    or preview["bytes"] <= 0
                    or not isinstance(preview.get("sha256"), str)
                    or not re.fullmatch(r"[0-9a-f]{64}", preview["sha256"])
                ):
                    raise SubsetReuseUnavailable("parent map preview identity is invalid")
                try:
                    preview_info = archive.getinfo(preview["path"])
                except KeyError as exc:
                    raise SubsetReuseUnavailable("parent map preview is missing") from exc
                preview_bytes = archive.read(preview_info)
                if (
                    preview_info.is_dir()
                    or preview_info.flag_bits & 0x1
                    or preview_info.compress_type != zipfile.ZIP_STORED
                    or preview_info.file_size != preview["bytes"]
                    or hashlib.sha256(preview_bytes).hexdigest() != preview["sha256"]
                ):
                    raise SubsetReuseUnavailable("parent map preview hash is invalid")
                files = manifest.get("files")
                if not isinstance(files, list) or not files:
                    raise SubsetReuseUnavailable("parent map manifest has no files")

                manifest_paths: set[str] = set()
                copied_font_asset = False
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
                    is_font_asset = parts[2:] == ["assets", "street-labels.fma"]
                    if block not in required and not is_font_asset:
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
                    destination_relative = (
                        f"VECTMAP/{child_map_id}/assets/street-labels.fma"
                        if is_font_asset
                        else child_pack_path(child_map_id, block, extension)
                    )
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
                        copied_fmb_blocks.add(block)
                    if is_font_asset:
                        copied_font_asset = True
        except SubsetReuseUnavailable:
            raise
        except (OSError, ValueError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
            raise SubsetReuseUnavailable(f"parent map pack is invalid: {exc}") from exc

        self._validate_reuse_artifact_records(parent, manifest, preview_bytes)
        if copied_fmb_blocks != required:
            raise SubsetReuseUnavailable(
                "parent map does not contain every required binary block"
            )
        if (
            renderer_format_version(child.request) in {
                LABEL_RENDERER_FORMAT_VERSION,
                BUILDING_RENDERER_FORMAT_VERSION,
            }
            and not copied_font_asset
        ):
            raise SubsetReuseUnavailable("parent label-aware map has no label font asset")
        return manifest

    def _validate_reuse_artifact_records(
        self,
        candidate: MapJob,
        manifest: dict[str, Any],
        preview_bytes: bytes,
    ) -> None:
        formats = [artifact.format for artifact in candidate.artifacts]
        object_keys = [artifact.object_key for artifact in candidate.artifacts]
        if (
            len(formats) != len(set(formats))
            or len(object_keys) != len(set(object_keys))
            or formats.count(ZIP_STORED_FORMAT) != 1
            or any(
                value not in {ZIP_STORED_FORMAT, BIKE_MAP_STREAM_FORMAT}
                for value in formats
            )
        ):
            raise SubsetReuseUnavailable("parent artifact set is ambiguous")
        stream = next(
            (
                artifact
                for artifact in candidate.artifacts
                if artifact.format == BIKE_MAP_STREAM_FORMAT
            ),
            None,
        )
        if stream is None:
            return
        if (
            stream.filename != f"{candidate.map_id}.bmap"
            or stream.media_type != BIKE_MAP_STREAM_MEDIA_TYPE
            or (
                stream.producer_build_sha256 is not None
                and stream.producer_build_sha256 != self.producer_build_sha256
            )
            or (
                stream.producer_image_digest is not None
                and stream.producer_image_digest != self.producer_image_digest
            )
        ):
            raise SubsetReuseUnavailable("parent map stream identity is invalid")
        stream_manifest = json.loads(json.dumps(manifest))
        stream_manifest["preview"]["dataBase64"] = base64.b64encode(
            preview_bytes
        ).decode("ascii")
        stream_manifest["producer"] = {
            "buildSha256": self.producer_build_sha256,
            "imageDigest": self.producer_image_digest,
        }
        expected_manifest_bytes = canonical_stream_manifest_bytes(stream_manifest)
        expected_receipt = manifest_receipt(expected_manifest_bytes)
        if stream.manifest_receipt != expected_receipt:
            raise SubsetReuseUnavailable(
                "parent map stream does not match the ZIP manifest"
            )
        if self.artifact_store is None or not hasattr(
            self.artifact_store, "read_prefix"
        ):
            raise SubsetReuseUnavailable("parent map stream cannot be inspected")
        maximum_prefix = (
            FIXED_HEADER_BYTES
            + MAX_MANIFEST_BYTES
            + 4
            + MAX_KEY_ID_BYTES
            + RAW_P256_SIGNATURE_BYTES
        )
        prefix = self.artifact_store.read_prefix(
            stream.object_key,
            maximum_bytes=maximum_prefix,
        )
        try:
            if not isinstance(prefix, bytes) or len(prefix) < FIXED_HEADER_BYTES:
                raise ValueError("stream prefix is missing")
            header = MapStreamHeader.decode(prefix[:FIXED_HEADER_BYTES])
            signed_prefix_bytes = (
                FIXED_HEADER_BYTES
                + header.manifest_bytes
                + header.signature_envelope_bytes
            )
            if len(prefix) < signed_prefix_bytes or header.total_bytes != stream.bytes:
                raise ValueError("stream prefix length is invalid")
            actual_manifest = prefix[
                FIXED_HEADER_BYTES : FIXED_HEADER_BYTES + header.manifest_bytes
            ]
            envelope_bytes = prefix[
                FIXED_HEADER_BYTES + header.manifest_bytes : signed_prefix_bytes
            ]
            envelope = MapStreamSignatureEnvelope.decode(envelope_bytes)
            if (
                actual_manifest != expected_manifest_bytes
                or manifest_receipt(actual_manifest) != stream.manifest_receipt
                or signed_manifest_receipt(actual_manifest, envelope_bytes)
                != stream.signed_manifest_receipt
                or envelope.key_id != stream.signature_key_id
                or header.file_count != len(json.loads(actual_manifest)["files"])
                or header.payload_bytes
                != sum(entry["bytes"] for entry in json.loads(actual_manifest)["files"])
            ):
                raise ValueError("stream identity does not match")
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise SubsetReuseUnavailable(
                "parent map stream bytes do not match the ZIP manifest"
            ) from exc

    def _stage_vectmap(self, raw_output_dir: Path, vectmap_output: Path) -> None:
        if not raw_output_dir.exists():
            raise FileNotFoundError(f"OSM_Extract output is missing: {raw_output_dir}")
        vectmap_output.mkdir(parents=True, exist_ok=True)
        for child in raw_output_dir.iterdir():
            destination = vectmap_output / child.name
            if child.is_dir():
                shutil.copytree(child, destination)
            elif child.suffix in {".fmb", ".fmp", ".fma"}:
                shutil.copy2(child, destination)

    def _pipeline_metadata(self) -> PipelineMetadata:
        return PipelineMetadata(
            osmium_version="producer-image-pinned",
            osm_extract_revision=self.producer_build_sha256 or "unknown",
            image_digest=self.producer_image_digest or "unknown",
        )


def run_job(
    store,
    pipeline: MapBuildPipeline,
    job_id: str,
    *,
    heartbeat_interval_seconds: float = 30.0,
    monitoring_store: MapMonitoringStore | None = None,
) -> MapJob:
    worker_id = f"api-{uuid.uuid4().hex[:8]}"
    job = store.claim(job_id, worker_id)
    attempt_started_monotonic = time.monotonic()

    def record_monitoring(job: MapJob) -> None:
        if monitoring_store is None:
            return
        try:
            monitoring_store.record_job(job)
        except Exception:
            # Observability must never turn a completed map into a failed map.
            pass

    def update(status: JobStatus) -> None:
        store.update_status_unless_cancelled(job_id, status, worker_id=worker_id)

    def update_progress(completed: int, total: int) -> None:
        store.update_progress_unless_cancelled(job_id, completed, total, worker_id=worker_id)

    def update_phase_progress(progress: dict[str, Any]) -> None:
        observability = getattr(job, "_building_observability", None)
        if observability is None:
            observability = {
                "attemptStartedMonotonic": attempt_started_monotonic,
            }
            job._building_observability = observability
        if "firstProgressMilliseconds" not in observability:
            observability["firstProgressMilliseconds"] = max(
                0,
                int(round((time.monotonic() - attempt_started_monotonic) * 1_000)),
            )
        store.update_phase_progress_unless_cancelled(
            job_id,
            phase=progress["phase"],
            unit=progress["unit"],
            completed=progress.get("completed"),
            total=progress.get("total"),
            completed_blocks=progress.get("completedBlocks"),
            total_blocks=progress.get("totalBlocks"),
            indeterminate=progress["indeterminate"],
            worker_id=worker_id,
        )

    def cancellation_requested() -> bool:
        current = store.get(job_id)
        return current.status == JobStatus.CANCELLED or current.worker_id != worker_id

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
                build_kwargs["on_phase_progress"] = update_phase_progress
                build_kwargs["cancellation_check"] = cancellation_requested
                build_kwargs["artifact_publication_lease"] = lambda object_key: (
                    store.artifact_publication_lease(
                        job_id,
                        object_key,
                        worker_id=worker_id,
                    )
                )
            if isinstance(pipeline, MapBuildPipeline):
                selected_preprocessing = pipeline.uses_selected_preprocessing(job)
                if job.building_preprocessing_mode is not None:
                    store.freeze_building_preprocessing_mode_unless_cancelled(
                        job_id,
                        worker_id=worker_id,
                        building_preprocessing_mode=(
                            job.building_preprocessing_mode
                        ),
                    )
                if selected_preprocessing:
                    update(JobStatus.CONVERTING_FEATURES)
            reuse_identity = (
                pipeline.reuse_keys(
                    job,
                    on_phase_progress=update_phase_progress,
                    cancellation_check=cancellation_requested,
                )
                if isinstance(pipeline, MapBuildPipeline)
                else None
            )
            if job.building_preprocessing_inputs is not None:
                store.freeze_building_preprocessing_inputs_unless_cancelled(
                    job_id,
                    worker_id=worker_id,
                    building_preprocessing_inputs=(
                        job.building_preprocessing_inputs
                    ),
                    building_preprocessing_runtime=(
                        job.building_preprocessing_runtime
                    ),
                )
            reuse_strategy = None
            reuse_source_job_id = None
            if reuse_identity is not None:
                with pipeline.exact_reuse_identity_lease(
                    job,
                    on_phase_progress=update_phase_progress,
                    cancellation_check=cancellation_requested,
                ) as confirmed:
                    if confirmed is None:
                        raise RuntimeError(
                            "map build identity became unavailable under source lease"
                        )
                    reuse_identity = confirmed
                    reserved = store.set_build_keys_unless_cancelled(
                        job_id,
                        worker_id=worker_id,
                        build_cache_key=reuse_identity.exact,
                        build_compatibility_key=reuse_identity.compatibility,
                        building_preprocessing_inputs=(
                            job.building_preprocessing_inputs
                        ),
                    )
                    job.build_cache_key = reserved.build_cache_key
                    job.build_compatibility_key = reserved.build_compatibility_key
                    exact = store.find_exact_reuse_candidate(
                        job_id=job_id,
                        build_cache_key=reuse_identity.exact,
                    )
                    if exact is not None and pipeline.validate_exact_reuse_candidate(
                        job, exact
                    ):
                        reused = store.complete_exact_reuse(
                            job_id,
                            worker_id=worker_id,
                            source_job_id=exact.job_id,
                            build_cache_key=reuse_identity.exact,
                            build_compatibility_key=reuse_identity.compatibility,
                            building_observability=deepcopy(
                                getattr(job, "_building_observability", {})
                            ),
                        )
                        if reused is not None:
                            record_monitoring(reused)
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
        finished = store.complete_job(
            job_id,
            worker_id=worker_id,
            map_id=map_id,
            built_archive=archive_path,
            published_archive=published_archive,
            artifacts=getattr(build_result, "artifacts", None),
            artifact_metrics=getattr(build_result, "artifact_metrics", None),
            build_cache_key=(
                getattr(build_result, "build_cache_key", None)
                or (reuse_identity.exact if reuse_identity else None)
            ),
            build_cache_aliases=(
                getattr(build_result, "build_cache_aliases", None) or []
            ),
            build_identity_derivation=getattr(
                build_result, "build_identity_derivation", None
            ),
            build_compatibility_key=(
                getattr(build_result, "build_compatibility_key", None)
                or (reuse_identity.compatibility if reuse_identity else None)
            ),
            reuse_strategy=reuse_strategy,
            reuse_source_job_id=reuse_source_job_id,
        )
        record_monitoring(finished)
        return finished
    except Exception as exc:
        if isinstance(pipeline, MapBuildPipeline):
            try:
                pipeline.cleanup_failed_attempt(job)
            except OSError:
                pass
        current = store.get(job_id)
        if current.status == JobStatus.CANCELLED or current.worker_id != worker_id:
            if (
                current.status == JobStatus.CANCELLED
                and isinstance(pipeline, MapBuildPipeline)
                and pipeline.artifact_store is not None
            ):
                store.queue_terminal_pending_artifacts(job_id)
                current = store.get(job_id)
            record_monitoring(current)
            return current
        error_message, error_code = safe_build_failure(job, exc)
        failed = store.update_status_unless_cancelled(
            job_id,
            JobStatus.FAILED,
            error=error_message,
            error_code=error_code,
            worker_id=worker_id,
        )
        if isinstance(pipeline, MapBuildPipeline) and pipeline.artifact_store is not None:
            store.queue_terminal_pending_artifacts(job_id)
            failed = store.get(job_id)
        record_monitoring(failed)
        return failed
