from __future__ import annotations

import hashlib
import json
import math
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Protocol

from .building_identity import (
    BUILDING_CLOSURE_ALGORITHM_VERSION,
    BUILDING_EXTRACTION_ALGORITHM_VERSION,
    BUILDING_SOURCE_INDEX_ALGORITHM_VERSION,
)
from .building_scope import BUILDING_SCOPE_POLICY_VERSION
from .map_buildings import BUILDING_PROFILE_VERSION
from .map_labels import renderer_format_version
from .models import JobStatus, MapJob, utc_now_iso


PUBLIC_SCHEMA_VERSION = 1
ESTIMATOR_CONTEXT_SCHEMA_VERSION = 1
MAX_PUBLIC_SECONDS = 604_800
MAX_ESTIMATE_REVISIONS = 16
MAX_COUNTER = 9_000_000_000_000_000
PUBLIC_STATES = frozenset({"pending", "available", "unavailable"})
PUBLIC_CONFIDENCE = frozenset({"low", "medium", "high"})
PUBLIC_BASIS = frozenset(
    {
        "baseline_profile",
        "historical_cohort",
        "queue_baseline",
        "queue_history",
        "queue_topology",
        "worker_profile",
        "scope_plan",
        "source_index",
        "relation_closure",
        "feature_complexity",
        "calibration_hit",
        "calibration_miss",
        "reuse_exact",
        "reuse_subset",
        "phase_progress",
        "retry",
    }
)
UNAVAILABLE_REASONS = frozenset(
    {"insufficient_data", "incompatible_worker", "temporarily_unavailable"}
)
OUTCOME_CLASSES = frozenset(
    {"full_build", "exact_reuse", "subset_reuse", "retry", "failure"}
)
COMPLETED_BY_PHASE = {
    "validating": frozenset(),
    "resolving_source": frozenset(),
    "extracting_pbf": frozenset(),
    "converting_features": frozenset({"source"}),
    # This phase is emitted for several selected-area substeps, including the
    # scope plan before source extraction starts. Its completed work therefore
    # comes from the typed progress unit below rather than the phase name.
    "building_preprocessing": frozenset(),
    "block_encoding": frozenset({"source", "dependencies", "normalization", "conversion"}),
    "packaging": frozenset({"source", "dependencies", "normalization", "conversion", "encoding"}),
}


class PreparationEstimateMode(str, Enum):
    OFF = "off"
    SHADOW = "shadow"
    PUBLIC = "public"

    @classmethod
    def from_environment(cls) -> "PreparationEstimateMode":
        value = os.environ.get(
            "MAP_PLATFORM_PREPARATION_ESTIMATES_MODE", "off"
        ).strip().lower()
        try:
            return cls(value)
        except ValueError as exc:
            raise ValueError(
                "MAP_PLATFORM_PREPARATION_ESTIMATES_MODE must be off, shadow, or public"
            ) from exc


@dataclass(frozen=True)
class PreparationEstimateConfig:
    mode: PreparationEstimateMode
    worker_class: str
    worker_concurrency_class: str
    validated_confidence_cap: str = "low"
    minimum_history_samples: int = 20
    high_confidence_samples: int = 50
    max_revisions_per_job: int = MAX_ESTIMATE_REVISIONS
    minimum_update_seconds: float = 5.0
    material_change_basis_points: int = 1_000
    max_seconds: int = MAX_PUBLIC_SECONDS

    def __post_init__(self) -> None:
        if (
            isinstance(self.minimum_history_samples, bool)
            or isinstance(self.high_confidence_samples, bool)
            or self.minimum_history_samples < 1
            or self.high_confidence_samples < self.minimum_history_samples
        ):
            raise ValueError(
                "high-confidence samples must be at least the history minimum"
            )

    @classmethod
    def from_environment(cls) -> "PreparationEstimateConfig":
        worker_class = os.environ.get(
            "MAP_PLATFORM_ESTIMATOR_WORKER_CLASS", "unclassified"
        ).strip()
        concurrency = os.environ.get(
            "MAP_PLATFORM_ESTIMATOR_WORKER_CONCURRENCY_CLASS", "single"
        ).strip()
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", worker_class):
            raise ValueError("estimator worker class is invalid")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", concurrency):
            raise ValueError("estimator worker concurrency class is invalid")
        confidence_cap = os.environ.get(
            "MAP_PLATFORM_ESTIMATE_VALIDATED_CONFIDENCE", "low"
        ).strip().lower()
        if confidence_cap not in PUBLIC_CONFIDENCE:
            raise ValueError(
                "MAP_PLATFORM_ESTIMATE_VALIDATED_CONFIDENCE must be low, medium, or high"
            )
        return cls(
            mode=PreparationEstimateMode.from_environment(),
            worker_class=worker_class,
            worker_concurrency_class=concurrency,
            validated_confidence_cap=confidence_cap,
            minimum_history_samples=_environment_int(
                "MAP_PLATFORM_ESTIMATE_MIN_HISTORY_SAMPLES", 20, 1, 10_000
            ),
            high_confidence_samples=_environment_int(
                "MAP_PLATFORM_ESTIMATE_HIGH_CONFIDENCE_SAMPLES", 50, 1, 10_000
            ),
            max_revisions_per_job=_environment_int(
                "MAP_PLATFORM_ESTIMATE_MAX_REVISIONS_PER_JOB", 16, 1, 256
            ),
            minimum_update_seconds=float(
                _environment_int(
                    "MAP_PLATFORM_ESTIMATE_MIN_UPDATE_SECONDS", 5, 0, 3_600
                )
            ),
            material_change_basis_points=_environment_int(
                "MAP_PLATFORM_ESTIMATE_MATERIAL_CHANGE_BPS", 1_000, 0, 10_000
            ),
            max_seconds=_environment_int(
                "MAP_PLATFORM_ESTIMATE_MAX_SECONDS",
                MAX_PUBLIC_SECONDS,
                60,
                MAX_PUBLIC_SECONDS,
            ),
        )


@dataclass(frozen=True)
class BaselineProfile:
    document: dict[str, Any]
    sha256: str

    @property
    def model_version(self) -> str:
        return str(self.document["modelVersion"])

    @property
    def feature_schema_version(self) -> int:
        return int(self.document["featureSchemaVersion"])

    @classmethod
    def load(cls, path: str | Path) -> "BaselineProfile":
        raw = Path(path).read_bytes()
        value = json.loads(raw)
        _validate_profile(value)
        return cls(
            document=value,
            sha256=hashlib.sha256(_canonical_json(value)).hexdigest(),
        )

    def baseline(self, renderer: int, preprocessing_mode: str) -> dict[str, Any]:
        by_renderer = self.document["baselines"].get(str(renderer))
        if not isinstance(by_renderer, dict):
            raise ValueError("baseline renderer is unavailable")
        candidate = by_renderer.get(preprocessing_mode) or by_renderer.get("legacy")
        if not isinstance(candidate, dict):
            raise ValueError("baseline preprocessing mode is unavailable")
        return candidate

    def reuse_range(self, outcome_class: str) -> tuple[int, int]:
        value = self.document["reuseBaselines"][outcome_class]
        return int(value[0]), int(value[1])


class EstimateHistory(Protocol):
    def estimate_samples(
        self,
        *,
        performance_key: str,
        renderer: int,
        preprocessing_mode: str,
        outcome_class: str,
        claimed: bool,
        source_region_id: str | None = None,
        output_block_count: int | None = None,
        source_area_m2: int | None = None,
        building_source_count: int | None = None,
        cache_outcome: str | None = None,
        minimum_samples: int = 20,
        limit: int = 500,
    ) -> list[float]: ...

    def queue_samples(
        self, *, performance_key: str, renderer: int, limit: int = 500
    ) -> list[float]: ...

    def record_estimate_revision(self, job: MapJob) -> bool: ...


class PreparationEstimator:
    def __init__(
        self,
        profile: BaselineProfile,
        config: PreparationEstimateConfig,
        history: EstimateHistory | None = None,
        *,
        clock=None,
    ):
        self.profile = profile
        self.config = config
        self.history = history
        self._clock = clock or time.time

    def initial_context(
        self,
        job: MapJob,
        *,
        preprocessing_mode: str,
        rules_sha256: str,
        queue_depth: int,
        queued_estimates: Iterable[Mapping[str, Any]] = (),
        compatible_worker_count: int = 0,
        producer_build_sha256: str | None = None,
        producer_image_digest: str | None = None,
    ) -> dict[str, Any]:
        renderer = renderer_format_version(job.request)
        effective_preprocessing_mode = (
            preprocessing_mode if renderer == 3 else "legacy"
        )
        performance_key = performance_compatibility_key(
            profile=self.profile,
            config=self.config,
            renderer=renderer,
            preprocessing_mode=effective_preprocessing_mode,
            rules_sha256=rules_sha256,
        )
        queue, queue_basis = self._queue_range(
            performance_key=performance_key,
            renderer=renderer,
            queue_depth=queue_depth,
            queued_estimates=queued_estimates,
            compatible_worker_count=compatible_worker_count,
        )
        return validate_estimator_context(
            {
                "schemaVersion": ESTIMATOR_CONTEXT_SCHEMA_VERSION,
                "rendererFormatVersion": renderer,
                "preprocessingMode": effective_preprocessing_mode,
                "performanceCompatibilityKey": performance_key,
                "modelVersion": self.profile.model_version,
                "profileSha256": self.profile.sha256,
                "workerClass": self.config.worker_class,
                "workerConcurrencyClass": self.config.worker_concurrency_class,
                "producerBuildSha256": _optional_identity(producer_build_sha256, image=False),
                "producerImageDigest": _optional_identity(producer_image_digest, image=True),
                "outcomeClass": "full_build",
                "queueDepth": min(max(int(queue_depth), 0), 10_000),
                "queueRange": queue,
                "queueBasis": queue_basis,
                "evidence": {},
            }
        )

    def estimate(
        self,
        job: MapJob,
        context: Mapping[str, Any],
        *,
        revision: int,
        based_on_phase: str | None = None,
    ) -> dict[str, Any]:
        normalized_context = validate_estimator_context(context)
        phase = based_on_phase or job.progress_phase or job.status.value
        generated_at = _iso_from_epoch(self._clock())
        common: dict[str, Any] = {
            "schemaVersion": PUBLIC_SCHEMA_VERSION,
            "modelVersion": self.profile.model_version,
            "revision": revision,
            "state": "available",
            "generatedAt": generated_at,
            "attempt": int(job.attempts),
            "basedOnPhase": phase,
        }
        try:
            lower, upper, queue, basis, sample_count = self._range(
                job, normalized_context, phase
            )
        except (KeyError, TypeError, ValueError, OverflowError):
            return validate_preparation_estimate(
                {
                    **common,
                    "state": "unavailable",
                    "reason": "temporarily_unavailable",
                },
                max_seconds=self.config.max_seconds,
            )
        sample_confidence = (
            "high"
            if sample_count >= self.config.high_confidence_samples
            else "medium"
            if sample_count >= self.config.minimum_history_samples
            else "low"
        )
        confidence_order = ("low", "medium", "high")
        confidence = confidence_order[
            min(
                confidence_order.index(sample_confidence),
                confidence_order.index(self.config.validated_confidence_cap),
            )
        ]
        result = {
            **common,
            "confidence": confidence,
            "remaining": {"lowerSeconds": lower, "upperSeconds": upper},
            "basis": basis,
            "sampleCount": sample_count,
        }
        if queue is not None and queue[1] > 0:
            result["queue"] = {
                "lowerSeconds": queue[0],
                "upperSeconds": queue[1],
            }
        return validate_preparation_estimate(
            result, max_seconds=self.config.max_seconds
        )

    def pending(
        self,
        job: MapJob,
        *,
        revision: int,
        based_on_phase: str | None = None,
    ) -> dict[str, Any]:
        return validate_preparation_estimate(
            {
                "schemaVersion": PUBLIC_SCHEMA_VERSION,
                "modelVersion": self.profile.model_version,
                "revision": revision,
                "state": "pending",
                "generatedAt": _iso_from_epoch(self._clock()),
                "attempt": int(job.attempts),
                "basedOnPhase": based_on_phase or job.status.value,
            },
            max_seconds=self.config.max_seconds,
        )

    def _range(
        self, job: MapJob, context: Mapping[str, Any], phase: str
    ) -> tuple[int, int, tuple[int, int] | None, list[str], int]:
        renderer = int(context["rendererFormatVersion"])
        preprocessing_mode = str(context["preprocessingMode"])
        outcome = str(context.get("outcomeClass", "full_build"))
        evidence = context.get("evidence", {})
        if outcome in {"exact_reuse", "subset_reuse"}:
            lower, upper = self.profile.reuse_range(outcome)
            basis = [
                "baseline_profile",
                "reuse_exact" if outcome == "exact_reuse" else "reuse_subset",
            ]
            samples = self._history_samples(
                job, context, renderer, preprocessing_mode, outcome, True
            )
            lower, upper = self._apply_history(lower, upper, samples)
            if samples:
                basis.append("historical_cohort")
            if upper > self.config.max_seconds:
                raise ValueError("estimate exceeds public range")
            return lower, upper, None, basis, len(samples)

        baseline = self.profile.baseline(renderer, preprocessing_mode)
        completed = set(COMPLETED_BY_PHASE.get(phase, ()))
        completed.update(_string_list(context.get("completedComponents"), 16))
        progress = evidence.get("progress") if isinstance(evidence, dict) else None
        if phase == "building_preprocessing" and isinstance(progress, dict):
            unit = progress.get("unit")
            if unit in {
                "source_index",
                "relation_closure",
                "dependency_snapshot",
                "building_normalization",
                "building_complexity",
            }:
                completed.add("source")
            if unit in {
                "dependency_snapshot",
                "building_normalization",
                "building_complexity",
            }:
                completed.update({"source", "dependencies"})
            if (
                unit == "building_normalization"
                and progress.get("completed") == progress.get("total")
                and _finite_nonnegative(progress.get("total"))
                and float(progress["total"]) > 0
            ):
                completed.add("normalization")
        all_components: dict[str, tuple[float, float]] = {
            name: (float(value[0]), float(value[1]))
            for name, value in baseline["components"].items()
        }
        scope = evidence.get("scope") if isinstance(evidence, dict) else None
        complexity = evidence.get("complexity") if isinstance(evidence, dict) else None
        scale_area = self._area_scale(job, baseline, scope)
        scale_blocks = self._block_scale(baseline, scope)
        for name in ("source", "dependencies", "conversion"):
            if name in all_components:
                all_components[name] = _scale_range(
                    all_components[name], scale_area
                )
        if "encoding" in all_components:
            all_components["encoding"] = _scale_range(
                all_components["encoding"], scale_blocks
            )
        if "normalization" in all_components:
            all_components["normalization"] = _scale_range(
                all_components["normalization"],
                self._normalization_scale(baseline, complexity, scale_area),
            )
        components = {
            name: value
            for name, value in all_components.items()
            if name not in completed
        }
        if "encoding" in components:
            if isinstance(progress, dict) and progress.get("phase") == "block_encoding":
                completed_blocks = progress.get("completed")
                total_blocks = progress.get("total")
                if (
                    _finite_nonnegative(completed_blocks)
                    and _finite_nonnegative(total_blocks)
                    and float(total_blocks) > 0
                ):
                    remaining_fraction = max(
                        0.0,
                        min(
                            1.0,
                            (float(total_blocks) - float(completed_blocks))
                            / float(total_blocks),
                        ),
                    )
                    components["encoding"] = _scale_range(
                        components["encoding"], remaining_fraction
                    )
        full_lower = math.floor(
            sum(value[0] for value in all_components.values())
        )
        full_upper = math.ceil(
            sum(value[1] for value in all_components.values()) * 1.05
        )
        lower = math.floor(sum(value[0] for value in components.values()))
        upper = math.ceil(sum(value[1] for value in components.values()) * 1.05)
        basis = ["baseline_profile"]
        if isinstance(scope, dict):
            basis.append("scope_plan")
        dependencies = evidence.get("dependencies") if isinstance(evidence, dict) else None
        if isinstance(dependencies, dict):
            if dependencies.get("sourceIndex"):
                basis.append("source_index")
            if dependencies.get("closure"):
                basis.append("relation_closure")
            cache_outcome = dependencies.get("cacheOutcome")
            if cache_outcome in {"hit", "filled_by_peer"}:
                basis.append("calibration_hit")
            elif cache_outcome in {"miss", "rebuilt"}:
                basis.append("calibration_miss")
        if isinstance(complexity, dict):
            basis.append("feature_complexity")
        if completed:
            basis.append("phase_progress")
        if int(job.attempts) > 1:
            basis.append("retry")

        claimed = job.started_at is not None and job.status != JobStatus.QUEUED
        samples = self._history_samples(
            job, context, renderer, preprocessing_mode, "full_build", claimed
        )
        if samples:
            calibrated_lower, calibrated_upper = self._apply_history(
                full_lower, full_upper, samples
            )
            lower = math.floor(
                calibrated_lower * lower / max(full_lower, 1)
            )
            upper = math.ceil(
                calibrated_upper * upper / max(full_upper, 1)
            )
            basis.append("historical_cohort")
        queue: tuple[int, int] | None = None
        if not claimed:
            queue_value = context.get("queueRange")
            if isinstance(queue_value, dict):
                queue = (
                    int(queue_value.get("lowerSeconds", 0)),
                    int(queue_value.get("upperSeconds", 0)),
                )
                lower += queue[0]
                upper += queue[1]
                basis.append(str(context.get("queueBasis", "queue_baseline")))
        lower = max(0, lower)
        upper = max(lower, upper)
        if upper > self.config.max_seconds:
            raise ValueError("estimate exceeds public range")
        return lower, upper, queue, _stable_basis(basis), len(samples)

    def _history_samples(
        self,
        job: MapJob,
        context: Mapping[str, Any],
        renderer: int,
        preprocessing_mode: str,
        outcome: str,
        claimed: bool,
    ) -> list[float]:
        if self.history is None:
            return []
        evidence = context.get("evidence")
        evidence = evidence if isinstance(evidence, Mapping) else {}
        scope = evidence.get("scope")
        scope = scope if isinstance(scope, Mapping) else {}
        complexity = evidence.get("complexity")
        complexity = complexity if isinstance(complexity, Mapping) else {}
        dependencies = evidence.get("dependencies")
        dependencies = dependencies if isinstance(dependencies, Mapping) else {}
        try:
            return [
                value
                for value in self.history.estimate_samples(
                    performance_key=str(context["performanceCompatibilityKey"]),
                    renderer=renderer,
                    preprocessing_mode=preprocessing_mode,
                    outcome_class=outcome,
                    claimed=claimed,
                    source_region_id=job.source_region.id,
                    output_block_count=_optional_counter(
                        scope.get("outputBlockCount")
                    ),
                    source_area_m2=_optional_counter(scope.get("sourceAreaM2")),
                    building_source_count=_optional_counter(
                        complexity.get("sourceCount")
                    ),
                    cache_outcome=(
                        dependencies.get("cacheOutcome")
                        if isinstance(dependencies.get("cacheOutcome"), str)
                        else None
                    ),
                    minimum_samples=self.config.minimum_history_samples,
                )
                if _finite_nonnegative(value)
            ]
        except Exception:
            return []

    def _apply_history(
        self, lower: int, upper: int, samples: list[float]
    ) -> tuple[int, int]:
        if not samples:
            return lower, upper
        ordered = sorted(samples)
        historical_lower = math.floor(_nearest_rank(ordered, 10))
        historical_upper = math.ceil(_nearest_rank(ordered, 95))
        if (
            len(ordered) < self.config.minimum_history_samples
            or self.config.validated_confidence_cap == "low"
        ):
            return min(lower, historical_lower), max(upper, historical_upper)
        return (
            max(0, math.floor(_nearest_rank(ordered, 25))),
            max(0, math.ceil(_nearest_rank(ordered, 90))),
        )

    def _queue_range(
        self,
        *,
        performance_key: str,
        renderer: int,
        queue_depth: int,
        queued_estimates: Iterable[Mapping[str, Any]],
        compatible_worker_count: int,
    ) -> tuple[dict[str, int], str]:
        if queue_depth <= 0:
            return (
                {"lowerSeconds": 0, "upperSeconds": 0},
                "queue_topology" if compatible_worker_count > 0 else "queue_baseline",
            )
        workers = max(compatible_worker_count, 1)
        ranges = [
            _available_work_range(value)
            for value in queued_estimates
            if isinstance(value, Mapping)
        ]
        ranges = [value for value in ranges if value is not None]
        if ranges:
            lower = math.floor(sum(value[0] for value in ranges) / workers)
            missing = max(0, int(queue_depth) - len(ranges))
            upper = math.ceil(
                (sum(value[1] for value in ranges) + missing * 900) / workers
            )
            return (
                {
                    "lowerSeconds": max(0, lower),
                    "upperSeconds": min(self.config.max_seconds, max(lower, upper)),
                },
                "queue_topology" if compatible_worker_count > 0 else "queue_baseline",
            )
        history: list[float] = []
        if self.history is not None:
            try:
                history = self.history.queue_samples(
                    performance_key=performance_key, renderer=renderer
                )
            except Exception:
                history = []
        history = [value for value in history if _finite_nonnegative(value)]
        if history:
            return (
                {
                    "lowerSeconds": math.floor(_nearest_rank(sorted(history), 25)),
                    "upperSeconds": math.ceil(_nearest_rank(sorted(history), 95)),
                },
                "queue_history",
            )
        return (
            {
                "lowerSeconds": 0,
                "upperSeconds": min(
                    self.config.max_seconds,
                    max(0, int(queue_depth)) * 900,
                ),
            },
            "queue_baseline",
        )

    @staticmethod
    def _area_scale(
        job: MapJob, baseline: Mapping[str, Any], scope: Any
    ) -> float:
        reference = float(baseline.get("referenceAreaM2", 100_000_000))
        area = (
            reference
            if "referenceBlocks" in baseline and not isinstance(scope, dict)
            else float(job.geometry.area_km2) * 1_000_000
        )
        if isinstance(scope, dict):
            area = float(scope.get("sourceAreaM2", area))
        ratio = max(area, 1.0) / max(reference, 1.0)
        return min(12.0, max(0.35, math.sqrt(ratio)))

    @staticmethod
    def _block_scale(baseline: Mapping[str, Any], scope: Any) -> float:
        if not isinstance(scope, dict):
            return 1.0
        reference = max(float(baseline.get("referenceBlocks", 1)), 1.0)
        blocks = max(float(scope.get("outputBlockCount", reference)), 1.0)
        return min(16.0, max(0.35, blocks / reference))

    @staticmethod
    def _normalization_scale(
        baseline: Mapping[str, Any], complexity: Any, fallback: float
    ) -> float:
        if not isinstance(complexity, dict):
            return fallback
        terms: list[float] = []
        for key, reference_key in (
            ("outlineCount", "referenceOutlines"),
            ("partCount", "referenceParts"),
            ("containmentCandidateProduct", "referenceContainmentProduct"),
            ("sourceVertexCount", "referenceVertices"),
        ):
            reference = baseline.get(reference_key)
            value = complexity.get(key)
            if _finite_nonnegative(reference) and _finite_nonnegative(value):
                terms.append(float(value) / max(float(reference), 1.0))
        if not terms:
            return fallback
        # Weighted toward the containment shape without allowing any increasing
        # feature to reduce the score.
        score = sum(terms) / len(terms)
        return min(20.0, max(0.25, score))


class PreparationEstimateCoordinator:
    """Own advisory estimate state while keeping failures out of map builds."""

    def __init__(
        self,
        store,
        estimator: PreparationEstimator,
        *,
        preprocessing_mode: str,
        rules_sha256: str,
        capability_store: "WorkerCapabilityStore | None" = None,
        producer_build_sha256: str | None = None,
        producer_image_digest: str | None = None,
        event_sink: Callable[[Mapping[str, Any]], None] | None = None,
        clock=None,
    ):
        self.store = store
        self.estimator = estimator
        self.config = estimator.config
        self.preprocessing_mode = preprocessing_mode
        self.rules_sha256 = rules_sha256
        self.capability_store = capability_store
        self.producer_build_sha256 = producer_build_sha256
        self.producer_image_digest = producer_image_digest
        self._event_sink = event_sink
        self._clock = clock or time.time

    @property
    def mode(self) -> PreparationEstimateMode:
        return self.config.mode

    def prepare_initial(self, job: MapJob, active_jobs: Iterable[MapJob]) -> None:
        if self.mode == PreparationEstimateMode.OFF:
            return
        active = list(active_jobs)
        renderer = renderer_format_version(job.request)
        effective_mode = self.preprocessing_mode if renderer == 3 else "legacy"
        expected_performance_key = performance_compatibility_key(
            profile=self.estimator.profile,
            config=self.config,
            renderer=renderer,
            preprocessing_mode=effective_mode,
            rules_sha256=self.rules_sha256,
        )
        capabilities = (
            self.capability_store.compatible(
                model_version=self.estimator.profile.model_version,
                performance_compatibility_key=expected_performance_key,
                profile_sha256=self.estimator.profile.sha256,
            )
            if self.capability_store is not None
            else []
        )
        context = self.estimator.initial_context(
            job,
            preprocessing_mode=self.preprocessing_mode,
            rules_sha256=self.rules_sha256,
            queue_depth=len(active),
            queued_estimates=(
                candidate.preparation_estimate
                for candidate in active
                if candidate.preparation_estimate is not None
            ),
            compatible_worker_count=len(capabilities),
            producer_build_sha256=self.producer_build_sha256,
            producer_image_digest=self.producer_image_digest,
        )
        context["compatibleWorkerCount"] = len(capabilities)
        job.preparation_estimator_context = context
        job.preparation_estimate = self.estimator.estimate(job, context, revision=1)

    def record_prepared(self, job: MapJob) -> None:
        self._record(job)

    def publish_worker_capability(self, worker_id: str) -> None:
        if self.mode == PreparationEstimateMode.OFF or self.capability_store is None:
            return
        try:
            keys = {
                performance_compatibility_key(
                    profile=self.estimator.profile,
                    config=self.config,
                    renderer=renderer,
                    preprocessing_mode=(
                        self.preprocessing_mode if renderer == 3 else "legacy"
                    ),
                    rules_sha256=self.rules_sha256,
                )
                for renderer in (1, 2, 3)
            }
            self.capability_store.publish(
                worker_id=worker_id,
                performance_compatibility_keys=keys,
                worker_class=self.config.worker_class,
                preprocessing_modes={self.preprocessing_mode},
                renderer_formats={1, 2, 3},
                model_version=self.estimator.profile.model_version,
                profile_sha256=self.estimator.profile.sha256,
            )
        except (OSError, TypeError, ValueError):
            # Capability publication refines API queue estimates only. A
            # transient sidecar failure must not break the worker heartbeat or
            # interrupt a map build.
            return

    def publish(
        self,
        job_id: str,
        *,
        worker_id: str | None,
        phase: str,
        evidence: Mapping[str, Any] | None = None,
        outcome_class: str | None = None,
        completed_components: Iterable[str] | None = None,
        force: bool = False,
    ) -> MapJob | None:
        if self.mode == PreparationEstimateMode.OFF:
            return None
        try:
            current = self.store.get(job_id)
            context = dict(current.preparation_estimator_context or {})
            if not self._context_matches_current(current, context):
                context = self.estimator.initial_context(
                    current,
                    preprocessing_mode=(
                        current.building_preprocessing_mode or self.preprocessing_mode
                    ),
                    rules_sha256=self.rules_sha256,
                    queue_depth=0,
                    producer_build_sha256=self.producer_build_sha256,
                    producer_image_digest=self.producer_image_digest,
                )
                context["compatibleWorkerCount"] = 1
            merged_evidence = dict(context.get("evidence", {}))
            if evidence:
                for key, value in evidence.items():
                    if key in {"scope", "dependencies", "complexity", "progress"}:
                        merged_evidence[key] = _bounded_json_value(value)
            context["evidence"] = merged_evidence
            if outcome_class is not None:
                if outcome_class not in OUTCOME_CLASSES:
                    raise ValueError("estimate outcome class is invalid")
                context["outcomeClass"] = outcome_class
            if completed_components is not None:
                context["completedComponents"] = sorted(
                    set(_string_list(list(completed_components), 16))
                )
            previous = current.preparation_estimate
            previous_revision = int(previous.get("revision", 0)) if previous else 0
            if previous_revision >= self.config.max_revisions_per_job:
                return current
            revision = previous_revision + 1
            candidate = self.estimator.estimate(
                current, context, revision=revision, based_on_phase=phase
            )
            if not force and not self._material_change(previous, candidate):
                return current
            updated = self.store.update_preparation_estimate_unless_cancelled(
                job_id,
                preparation_estimate=candidate,
                estimator_context=context,
                worker_id=worker_id,
            )
            self._record(updated)
            return updated
        except Exception:
            return None

    def publish_pending_retry(self, job_id: str, *, worker_id: str) -> None:
        if self.mode == PreparationEstimateMode.OFF:
            return
        try:
            current = self.store.get(job_id)
            current_revision = int(
                (current.preparation_estimate or {}).get("revision", 0)
            )
            if current_revision >= self.config.max_revisions_per_job:
                return
            revision = current_revision + 1
            estimate = self.estimator.pending(
                current, revision=revision, based_on_phase="retry"
            )
            context = dict(current.preparation_estimator_context or {})
            context["outcomeClass"] = "retry"
            updated = self.store.update_preparation_estimate_unless_cancelled(
                job_id,
                preparation_estimate=estimate,
                estimator_context=context,
                worker_id=worker_id,
            )
            self._record(updated)
        except Exception:
            return

    def _material_change(
        self,
        previous: Mapping[str, Any] | None,
        candidate: Mapping[str, Any],
    ) -> bool:
        if not previous:
            return True
        if previous.get("state") != candidate.get("state"):
            return True
        if previous.get("basedOnPhase") != candidate.get("basedOnPhase"):
            return True
        previous_at = _epoch_from_iso(previous.get("generatedAt"))
        if (
            previous_at is not None
            and self._clock() - previous_at < self.config.minimum_update_seconds
        ):
            return False
        old_range = _available_range(previous)
        new_range = _available_range(candidate)
        if old_range is None or new_range is None:
            return previous != candidate
        denominator = max(old_range[1], 1)
        delta_bps = max(
            abs(new_range[0] - old_range[0]),
            abs(new_range[1] - old_range[1]),
        ) * 10_000 / denominator
        return delta_bps >= self.config.material_change_basis_points

    def _context_matches_current(
        self, job: MapJob, context: Mapping[str, Any]
    ) -> bool:
        if not context:
            return False
        renderer = renderer_format_version(job.request)
        mode = (
            job.building_preprocessing_mode or self.preprocessing_mode
            if renderer == 3
            else "legacy"
        )
        expected_key = performance_compatibility_key(
            profile=self.estimator.profile,
            config=self.config,
            renderer=renderer,
            preprocessing_mode=mode,
            rules_sha256=self.rules_sha256,
        )
        return (
            context.get("modelVersion") == self.estimator.profile.model_version
            and context.get("profileSha256") == self.estimator.profile.sha256
            and context.get("performanceCompatibilityKey") == expected_key
            and (
                self.producer_build_sha256 is None
                or context.get("producerBuildSha256")
                == self.producer_build_sha256
            )
            and (
                self.producer_image_digest is None
                or context.get("producerImageDigest")
                == self.producer_image_digest
            )
        )

    def _record(self, job: MapJob) -> None:
        if job.preparation_estimate is None:
            return
        if self.estimator.history is not None:
            try:
                self.estimator.history.record_estimate_revision(job)
            except Exception:
                pass
        if self._event_sink is not None:
            try:
                estimate = job.preparation_estimate
                context = job.preparation_estimator_context or {}
                event: dict[str, Any] = {
                    "event": "map_preparation_estimate_updated",
                    "jobId": job.job_id,
                    "revision": estimate["revision"],
                    "attempt": estimate["attempt"],
                    "state": estimate["state"],
                    "modelVersion": estimate["modelVersion"],
                    "performanceProfilePrefix": str(
                        context.get("performanceCompatibilityKey", "")
                    )[:12],
                    "basedOnPhase": estimate["basedOnPhase"],
                }
                for key in ("remaining", "queue", "confidence", "basis"):
                    if key in estimate:
                        event[key] = estimate[key]
                self._event_sink(event)
            except Exception:
                pass


class DisabledPreparationEstimateCoordinator:
    """No-op rollout state that does not require estimator artifacts."""

    mode = PreparationEstimateMode.OFF

    def prepare_initial(self, job: MapJob, active_jobs: Iterable[MapJob]) -> None:
        return

    def record_prepared(self, job: MapJob) -> None:
        return

    def publish_worker_capability(self, worker_id: str) -> None:
        return

    def publish(self, *args, **kwargs) -> None:
        return None

    def publish_pending_retry(self, job_id: str, *, worker_id: str) -> None:
        return


class WorkerCapabilityStore:
    def __init__(self, root: str | Path, *, max_age_seconds: int = 120, clock=None):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.max_age_seconds = max_age_seconds
        self._clock = clock or time.time

    def publish(
        self,
        *,
        worker_id: str,
        performance_compatibility_key: str | None = None,
        performance_compatibility_keys: Iterable[str] = (),
        worker_class: str,
        preprocessing_modes: Iterable[str],
        renderer_formats: Iterable[int],
        model_version: str,
        profile_sha256: str | None = None,
    ) -> None:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", worker_id):
            raise ValueError("worker capability ID is invalid")
        keys = set(performance_compatibility_keys)
        if performance_compatibility_key is not None:
            keys.add(performance_compatibility_key)
        if not keys or any(re.fullmatch(r"[0-9a-f]{64}", key) is None for key in keys):
            raise ValueError("worker performance compatibility key is invalid")
        if profile_sha256 is not None and re.fullmatch(
            r"[0-9a-f]{64}", profile_sha256
        ) is None:
            raise ValueError("worker estimator profile hash is invalid")
        document = {
            "schemaVersion": 1,
            "workerId": worker_id,
            "performanceCompatibilityKeys": sorted(keys),
            "workerClass": worker_class,
            "preprocessingModes": sorted(set(preprocessing_modes)),
            "rendererFormats": sorted(set(int(value) for value in renderer_formats)),
            "modelVersion": model_version,
            "profileSha256": profile_sha256,
            "heartbeatEpoch": self._clock(),
        }
        path = self.root / f"{worker_id}.json"
        temporary = path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n"
        )
        temporary.replace(path)

    def compatible(
        self,
        *,
        model_version: str,
        performance_compatibility_key: str | None = None,
        profile_sha256: str | None = None,
    ) -> list[dict[str, Any]]:
        now = self._clock()
        result = []
        for path in sorted(self.root.glob("*.json")):
            try:
                value = json.loads(path.read_text())
                heartbeat = float(value["heartbeatEpoch"])
                keys = value.get("performanceCompatibilityKeys")
                if keys is None and isinstance(
                    value.get("performanceCompatibilityKey"), str
                ):
                    keys = [value["performanceCompatibilityKey"]]
                if (
                    value.get("schemaVersion") != 1
                    or value.get("modelVersion") != model_version
                    or (
                        profile_sha256 is not None
                        and value.get("profileSha256") != profile_sha256
                    )
                    or not isinstance(keys, list)
                    or any(
                        not isinstance(key, str)
                        or re.fullmatch(r"[0-9a-f]{64}", key) is None
                        for key in keys
                    )
                    or (
                        performance_compatibility_key is not None
                        and performance_compatibility_key not in keys
                    )
                    or not 0 <= now - heartbeat <= self.max_age_seconds
                ):
                    continue
                result.append(value)
            except (OSError, TypeError, ValueError, KeyError):
                continue
        return result


def load_estimate_coordinator(
    *,
    repo_root: Path,
    data_root: Path,
    store,
    monitoring_store: EstimateHistory | None,
    preprocessing_mode: str,
    producer_build_sha256: str | None = None,
    producer_image_digest: str | None = None,
) -> PreparationEstimateCoordinator | DisabledPreparationEstimateCoordinator:
    if PreparationEstimateMode.from_environment() == PreparationEstimateMode.OFF:
        return DisabledPreparationEstimateCoordinator()
    config = PreparationEstimateConfig.from_environment()
    profile_path = Path(
        os.environ.get(
            "MAP_PLATFORM_PREPARATION_ESTIMATE_MODEL_PATH",
            repo_root
            / "map-platform"
            / "backend"
            / "config"
            / "preparation-estimate-profile-v1.json",
        )
    )
    profile = BaselineProfile.load(profile_path)
    rules_path = (
        repo_root
        / "tools"
        / "OSM_Extract"
        / "conf"
        / "building_height_rules.yaml"
    )
    rules_sha256 = hashlib.sha256(rules_path.read_bytes()).hexdigest()
    estimator = PreparationEstimator(profile, config, monitoring_store)
    try:
        capability_store = WorkerCapabilityStore(
            data_root / "health" / "worker-capabilities"
        )
    except OSError:
        capability_store = None
    return PreparationEstimateCoordinator(
        store,
        estimator,
        preprocessing_mode=preprocessing_mode,
        rules_sha256=rules_sha256,
        capability_store=capability_store,
        producer_build_sha256=producer_build_sha256,
        producer_image_digest=producer_image_digest,
        event_sink=lambda event: print(
            json.dumps(event, sort_keys=True, separators=(",", ":")), flush=True
        ),
    )


def performance_compatibility_key(
    *,
    profile: BaselineProfile,
    config: PreparationEstimateConfig,
    renderer: int,
    preprocessing_mode: str,
    rules_sha256: str,
) -> str:
    value = {
        "estimatorFeatureSchemaVersion": profile.feature_schema_version,
        "runtimePerformanceProfileVersion": profile.document[
            "runtimePerformanceProfileVersion"
        ],
        "rendererFormatVersion": int(renderer),
        "preprocessingMode": preprocessing_mode,
        "scopePolicyVersion": profile.document["scopePolicyVersion"],
        "buildingProfileVersion": profile.document["buildingProfileVersion"],
        "buildingRulesSha256": rules_sha256,
        "algorithmVersions": profile.document["algorithmVersions"],
        "workerClass": config.worker_class,
        "workerConcurrencyClass": config.worker_concurrency_class,
        "validatedConfidenceCap": config.validated_confidence_cap,
    }
    return hashlib.sha256(_canonical_json(value)).hexdigest()


def validate_preparation_estimate(
    value: Any, *, max_seconds: int = MAX_PUBLIC_SECONDS
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("preparation estimate must be an object")
    required = {
        "schemaVersion",
        "modelVersion",
        "revision",
        "state",
        "generatedAt",
        "attempt",
        "basedOnPhase",
    }
    allowed = required | {
        "confidence",
        "remaining",
        "queue",
        "basis",
        "sampleCount",
        "reason",
    }
    if not required.issubset(value) or not set(value).issubset(allowed):
        raise ValueError("preparation estimate fields are invalid")
    if value["schemaVersion"] != PUBLIC_SCHEMA_VERSION:
        raise ValueError("preparation estimate schema is unsupported")
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", str(value["modelVersion"])):
        raise ValueError("preparation estimate model version is invalid")
    revision = _bounded_int(value["revision"], 1, 1_000_000)
    attempt = _bounded_int(value["attempt"], 0, 1_000)
    state = value["state"]
    if state not in PUBLIC_STATES:
        raise ValueError("preparation estimate state is invalid")
    generated_at = value["generatedAt"]
    if _epoch_from_iso(generated_at) is None:
        raise ValueError("preparation estimate timestamp is invalid")
    phase = value["basedOnPhase"]
    if not isinstance(phase, str) or not re.fullmatch(r"[a-z0-9_]{1,64}", phase):
        raise ValueError("preparation estimate phase is invalid")
    normalized: dict[str, Any] = {
        "schemaVersion": PUBLIC_SCHEMA_VERSION,
        "modelVersion": str(value["modelVersion"]),
        "revision": revision,
        "state": state,
        "generatedAt": str(generated_at),
        "attempt": attempt,
        "basedOnPhase": phase,
    }
    if state == "available":
        confidence = value.get("confidence")
        if confidence not in PUBLIC_CONFIDENCE:
            raise ValueError("preparation estimate confidence is invalid")
        remaining = _validate_range(value.get("remaining"), max_seconds)
        queue = value.get("queue")
        basis = value.get("basis")
        if (
            not isinstance(basis, list)
            or not basis
            or len(basis) > 24
            or any(item not in PUBLIC_BASIS for item in basis)
            or len(basis) != len(set(basis))
        ):
            raise ValueError("preparation estimate basis is invalid")
        sample_count = _bounded_int(value.get("sampleCount"), 0, 1_000_000)
        normalized.update(
            {
                "confidence": confidence,
                "remaining": remaining,
                "basis": list(basis),
                "sampleCount": sample_count,
            }
        )
        if queue is not None:
            normalized_queue = _validate_range(queue, max_seconds)
            if normalized_queue["upperSeconds"] > remaining["upperSeconds"]:
                raise ValueError("queue range exceeds remaining range")
            normalized["queue"] = normalized_queue
    elif state == "unavailable":
        reason = value.get("reason")
        if reason not in UNAVAILABLE_REASONS:
            raise ValueError("preparation estimate unavailable reason is invalid")
        normalized["reason"] = reason
    elif any(
        key in value
        for key in ("confidence", "remaining", "queue", "basis", "sampleCount", "reason")
    ):
        raise ValueError("pending estimate contains range fields")
    return normalized


def validate_estimator_context(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("estimator context must be an object")
    required = {
        "schemaVersion",
        "rendererFormatVersion",
        "preprocessingMode",
        "performanceCompatibilityKey",
        "modelVersion",
        "profileSha256",
        "workerClass",
        "workerConcurrencyClass",
        "outcomeClass",
        "queueDepth",
        "queueRange",
        "evidence",
    }
    allowed = required | {
        "producerBuildSha256",
        "producerImageDigest",
        "compatibleWorkerCount",
        "completedComponents",
        "queueBasis",
    }
    if not required.issubset(value) or not set(value).issubset(allowed):
        raise ValueError("estimator context fields are invalid")
    if value["schemaVersion"] != ESTIMATOR_CONTEXT_SCHEMA_VERSION:
        raise ValueError("estimator context schema is unsupported")
    renderer = _bounded_int(value["rendererFormatVersion"], 1, 3)
    mode = value["preprocessingMode"]
    if mode not in {"legacy", "shadow", "selected"}:
        raise ValueError("estimator preprocessing mode is invalid")
    for key in ("performanceCompatibilityKey", "profileSha256"):
        if not isinstance(value[key], str) or not re.fullmatch(r"[0-9a-f]{64}", value[key]):
            raise ValueError(f"estimator {key} is invalid")
    for key in ("modelVersion", "workerClass", "workerConcurrencyClass"):
        if not isinstance(value[key], str) or not re.fullmatch(
            r"[A-Za-z0-9._-]{1,64}", value[key]
        ):
            raise ValueError(f"estimator {key} is invalid")
    outcome = value["outcomeClass"]
    if outcome not in OUTCOME_CLASSES:
        raise ValueError("estimator outcome class is invalid")
    evidence = _bounded_json_value(value["evidence"])
    if not isinstance(evidence, dict):
        raise ValueError("estimator evidence is invalid")
    _validate_estimator_evidence(evidence)
    result = {
        "schemaVersion": ESTIMATOR_CONTEXT_SCHEMA_VERSION,
        "rendererFormatVersion": renderer,
        "preprocessingMode": mode,
        "performanceCompatibilityKey": value["performanceCompatibilityKey"],
        "modelVersion": value["modelVersion"],
        "profileSha256": value["profileSha256"],
        "workerClass": value["workerClass"],
        "workerConcurrencyClass": value["workerConcurrencyClass"],
        "outcomeClass": outcome,
        "queueDepth": _bounded_int(value["queueDepth"], 0, 10_000),
        "queueRange": _validate_range(value["queueRange"], MAX_PUBLIC_SECONDS),
        "evidence": evidence,
    }
    if value.get("producerBuildSha256") is not None:
        result["producerBuildSha256"] = _optional_identity(
            value["producerBuildSha256"], image=False
        )
    if value.get("producerImageDigest") is not None:
        result["producerImageDigest"] = _optional_identity(
            value["producerImageDigest"], image=True
        )
    if "compatibleWorkerCount" in value:
        result["compatibleWorkerCount"] = _bounded_int(
            value["compatibleWorkerCount"], 0, 1_000
        )
    queue_basis = value.get("queueBasis", "queue_baseline")
    if queue_basis not in {
        "queue_baseline",
        "queue_history",
        "queue_topology",
    }:
        raise ValueError("estimator queue basis is invalid")
    result["queueBasis"] = queue_basis
    if "completedComponents" in value:
        result["completedComponents"] = _string_list(
            value["completedComponents"], 16
        )
    return result


def _validate_profile(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion",
        "modelVersion",
        "featureSchemaVersion",
        "runtimePerformanceProfileVersion",
        "scopePolicyVersion",
        "buildingProfileVersion",
        "algorithmVersions",
        "baselines",
        "reuseBaselines",
    }:
        raise ValueError("preparation estimate profile fields are invalid")
    if value["schemaVersion"] != 1 or value["featureSchemaVersion"] != 1:
        raise ValueError("preparation estimate profile schema is unsupported")
    for key in ("modelVersion", "runtimePerformanceProfileVersion"):
        if not isinstance(value[key], str) or not re.fullmatch(
            r"[A-Za-z0-9._-]{1,64}", value[key]
        ):
            raise ValueError(f"preparation estimate {key} is invalid")
    if not isinstance(value["baselines"], dict) or set(value["baselines"]) != {
        "1",
        "2",
        "3",
    }:
        raise ValueError("preparation estimate baselines are invalid")
    if value["scopePolicyVersion"] != BUILDING_SCOPE_POLICY_VERSION:
        raise ValueError("preparation estimate scope policy is stale")
    if value["buildingProfileVersion"] != BUILDING_PROFILE_VERSION:
        raise ValueError("preparation estimate building profile is stale")
    expected_algorithms = {
        "buildingNormalization": BUILDING_EXTRACTION_ALGORITHM_VERSION,
        "buildingSourceIndex": BUILDING_SOURCE_INDEX_ALGORITHM_VERSION,
        "relationClosure": BUILDING_CLOSURE_ALGORITHM_VERSION,
    }
    if value["algorithmVersions"] != expected_algorithms:
        raise ValueError("preparation estimate algorithm profile is stale")
    component_names = {
        "source",
        "dependencies",
        "normalization",
        "conversion",
        "encoding",
        "packaging",
    }
    reference_fields = {
        "referenceAreaM2",
        "referenceBlocks",
        "referenceOutlines",
        "referenceParts",
        "referenceContainmentProduct",
        "referenceVertices",
    }
    for renderer, modes in value["baselines"].items():
        if renderer not in {"1", "2", "3"} or not isinstance(modes, dict):
            raise ValueError("preparation estimate renderer baseline is invalid")
        for baseline in modes.values():
            if (
                not isinstance(baseline, dict)
                or not set(baseline).issubset(reference_fields | {"components"})
                or not isinstance(baseline.get("components"), dict)
                or not baseline["components"]
                or not set(baseline["components"]).issubset(component_names)
                or "referenceAreaM2" not in baseline
            ):
                raise ValueError("preparation estimate baseline is invalid")
            for field in reference_fields & set(baseline):
                reference = baseline[field]
                if (
                    isinstance(reference, bool)
                    or not isinstance(reference, int)
                    or reference < (1 if field == "referenceAreaM2" else 0)
                    or reference > MAX_COUNTER
                ):
                    raise ValueError("preparation estimate reference is invalid")
            for component_range in baseline["components"].values():
                if not isinstance(component_range, list) or len(component_range) != 2:
                    raise ValueError("preparation estimate component is invalid")
                _validate_range(
                    {
                        "lowerSeconds": component_range[0],
                        "upperSeconds": component_range[1],
                    },
                    MAX_PUBLIC_SECONDS,
                )
    if not isinstance(value["reuseBaselines"], dict) or set(
        value["reuseBaselines"]
    ) != {"exact_reuse", "subset_reuse"}:
        raise ValueError("preparation estimate reuse baselines are invalid")
    for outcome in ("exact_reuse", "subset_reuse"):
        pair = value["reuseBaselines"][outcome]
        if not isinstance(pair, list) or len(pair) != 2:
            raise ValueError("preparation estimate reuse baseline is invalid")
        _validate_range(
            {"lowerSeconds": pair[0], "upperSeconds": pair[1]},
            MAX_PUBLIC_SECONDS,
        )


def _validate_range(value: Any, maximum: int) -> dict[str, int]:
    if not isinstance(value, dict) or set(value) != {
        "lowerSeconds",
        "upperSeconds",
    }:
        raise ValueError("preparation estimate range is invalid")
    lower = _bounded_int(value["lowerSeconds"], 0, maximum)
    upper = _bounded_int(value["upperSeconds"], 0, maximum)
    if lower > upper:
        raise ValueError("preparation estimate range is inverted")
    return {"lowerSeconds": lower, "upperSeconds": upper}


def _bounded_int(value: Any, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("bounded estimator value must be an integer")
    if not minimum <= value <= maximum:
        raise ValueError("bounded estimator value is out of range")
    return value


def _bounded_json_value(value: Any, *, depth: int = 0) -> Any:
    if depth > 6:
        raise ValueError("estimator context is nested too deeply")
    if value is None or isinstance(value, (str, bool)):
        if isinstance(value, str) and len(value) > 256:
            raise ValueError("estimator context string is too long")
        return value
    if isinstance(value, int) and not isinstance(value, bool):
        return _bounded_int(value, -MAX_COUNTER, MAX_COUNTER)
    if isinstance(value, float):
        if not math.isfinite(value) or abs(value) > MAX_COUNTER:
            raise ValueError("estimator context number is invalid")
        return value
    if isinstance(value, list):
        if len(value) > 128:
            raise ValueError("estimator context list is too long")
        return [_bounded_json_value(item, depth=depth + 1) for item in value]
    if isinstance(value, dict):
        if len(value) > 128:
            raise ValueError("estimator context object is too large")
        result = {}
        for key, item in value.items():
            if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", key):
                raise ValueError("estimator context key is invalid")
            result[key] = _bounded_json_value(item, depth=depth + 1)
        return result
    raise ValueError("estimator context value is invalid")


def _validate_estimator_evidence(evidence: Mapping[str, Any]) -> None:
    counter_sections = {
        "scope": {
            "outputBlockCount",
            "requestedApproximateAreaM2",
            "outputAreaM2",
            "sourceAreaM2",
            "sourceToOutputAreaBasisPoints",
            "calibrationCellCount",
            "calibrationSampleCellCount",
            "geometryBufferMeters",
        },
        "complexity": {
            "schemaVersion",
            "sourceCount",
            "outlineCount",
            "partCount",
            "explicitParentCount",
            "unresolvedPartCount",
            "containmentCandidateProduct",
            "polygonCount",
            "ringCount",
            "holeCount",
            "sourceVertexCount",
            "maximumVerticesPerObject",
            "preparationRejectedCount",
        },
        "progress": {"completed", "total"},
    }
    for section_name, fields in counter_sections.items():
        section = evidence.get(section_name)
        if not isinstance(section, Mapping):
            continue
        for field in fields & set(section):
            field_value = section[field]
            if section_name == "progress" and field_value is None:
                continue
            _bounded_int(field_value, 0, MAX_COUNTER)

    scope = evidence.get("scope")
    if isinstance(scope, Mapping) and "sourceBoundsE7" in scope:
        bounds = scope["sourceBoundsE7"]
        if (
            not isinstance(bounds, list)
            or len(bounds) != 4
            or any(
                isinstance(item, bool) or not isinstance(item, int)
                for item in bounds
            )
            or not -1_800_000_000 <= bounds[0] <= bounds[2] <= 1_800_000_000
            or not -900_000_000 <= bounds[1] <= bounds[3] <= 900_000_000
        ):
            raise ValueError("estimator source bounds are invalid")

    dependencies = evidence.get("dependencies")
    if not isinstance(dependencies, Mapping):
        return
    if "sourceBytes" in dependencies:
        _bounded_int(dependencies["sourceBytes"], 0, MAX_COUNTER)
    for section_name in ("sourceIndex", "closure"):
        section = dependencies.get(section_name)
        if not isinstance(section, Mapping):
            continue
        for field, field_value in section.items():
            if field.endswith("Count") or field in {
                "schemaVersion",
                "algorithmVersion",
            }:
                _bounded_int(field_value, 0, MAX_COUNTER)


def _string_list(value: Any, maximum: int) -> list[str]:
    if not isinstance(value, list) or len(value) > maximum:
        return []
    if any(
        not isinstance(item, str)
        or not re.fullmatch(r"[a-z0-9_]{1,64}", item)
        for item in value
    ):
        return []
    return list(value)


def _stable_basis(values: Iterable[str]) -> list[str]:
    result = []
    for value in values:
        if value in PUBLIC_BASIS and value not in result:
            result.append(value)
    return result


def _available_range(value: Mapping[str, Any]) -> tuple[int, int] | None:
    if value.get("state") != "available" or not isinstance(value.get("remaining"), Mapping):
        return None
    try:
        lower = int(value["remaining"]["lowerSeconds"])
        upper = int(value["remaining"]["upperSeconds"])
    except (KeyError, TypeError, ValueError):
        return None
    return (lower, upper) if 0 <= lower <= upper <= MAX_PUBLIC_SECONDS else None


def _available_work_range(value: Mapping[str, Any]) -> tuple[int, int] | None:
    """Return remaining work without recursively counting queued time."""
    remaining = _available_range(value)
    if remaining is None:
        return None
    queue = value.get("queue")
    if not isinstance(queue, Mapping):
        return remaining
    try:
        queue_lower = int(queue["lowerSeconds"])
        queue_upper = int(queue["upperSeconds"])
    except (KeyError, TypeError, ValueError):
        return remaining
    if not (
        0 <= queue_lower <= queue_upper <= MAX_PUBLIC_SECONDS
        and queue_upper <= remaining[1]
    ):
        return remaining
    lower = max(0, remaining[0] - queue_lower)
    upper = max(lower, remaining[1] - queue_upper)
    return lower, upper


def _scale_range(value: tuple[float, float], scale: float) -> tuple[float, float]:
    if not math.isfinite(scale) or scale < 0:
        raise ValueError("estimate scale is invalid")
    return value[0] * scale, value[1] * scale


def _nearest_rank(values: list[float], percentile: int) -> float:
    if not values:
        raise ValueError("quantile requires samples")
    index = max(0, math.ceil(percentile / 100 * len(values)) - 1)
    return values[min(index, len(values) - 1)]


def _finite_nonnegative(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
        and float(value) >= 0
    )


def _optional_counter(value: Any) -> int | None:
    if (
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= MAX_COUNTER
    ):
        return value
    return None


def _optional_identity(value: Any, *, image: bool) -> str | None:
    if value is None:
        return None
    pattern = r"sha256:[0-9a-f]{64}" if image else r"[0-9a-f]{64}"
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        return None
    return value


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode("utf-8")


def _iso_from_epoch(value: float) -> str:
    return datetime.fromtimestamp(value, tz=timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def _epoch_from_iso(value: Any) -> float | None:
    if not isinstance(value, str):
        return None
    try:
        normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
        parsed = datetime.fromisoformat(normalized)
        if parsed.tzinfo is None:
            return None
        result = parsed.astimezone(timezone.utc).timestamp()
        return result if math.isfinite(result) else None
    except (ValueError, OverflowError):
        return None


def _environment_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value
