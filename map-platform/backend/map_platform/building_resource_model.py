"""Conservative resource-model summaries for retained building task evidence."""

from __future__ import annotations

import hashlib
import json
import math
import re
from collections import defaultdict
from typing import Any, Iterable, Mapping


RESOURCE_MODEL_SCHEMA_VERSION = 1
DEFAULT_MINIMUM_OBSERVATIONS = 8
RESOURCE_MODEL_VERSION = "building-resource-model-untrained-v1"
CALIBRATED_RESOURCE_MODEL_VERSION = "building-resource-model-calibrated-v1"
CONSERVATIVE_MEMORY_MODEL_VERSION = "conservative-counter-floor-v1"
CONSERVATIVE_WALL_MODEL_VERSION = "conservative-counter-throughput-v1"
DEFAULT_UNKNOWN_WORKLOAD_MEMORY_RESERVATION_BYTES = 512 * 1024 * 1024
_SHA256 = re.compile(r"[0-9a-f]{64}")


def conservative_peak_memory_bytes(workload: Mapping[str, Any]) -> int:
    """Return an explicit pre-training memory reservation from raw counters.

    This is intentionally a coarse, versioned floor rather than a trained
    admission model.  It keeps an exact workload scan from being represented
    as a zero-byte task and becomes the prediction recorded beside the later
    measured RSS.  Operators must not promote this model to a higher
    concurrency policy without retained worker-class observations.
    """

    if not isinstance(workload, Mapping):
        raise ValueError("workload counters must be a mapping")

    def counter(name: str) -> int:
        value = workload.get(name, 0)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"workload counter {name} is invalid")
        return value

    estimate = DEFAULT_UNKNOWN_WORKLOAD_MEMORY_RESERVATION_BYTES
    estimate += counter("nodeCount") * 96
    estimate += counter("wayCount") * 640
    estimate += counter("relationCount") * 1_536
    estimate += counter("storedRelationMemberCount") * 96
    estimate += counter("wayNodeReferenceCount") * 48
    estimate += counter("vertexCount") * 48
    estimate += counter("candidateOutlineCount") * 2_048
    estimate += counter("candidatePartCount") * 2_048
    return estimate


def conservative_wall_seconds(workload: Mapping[str, Any]) -> int:
    """Estimate one cold chunk's wall time from exact workload counters.

    The floor is intentionally simple and reviewable: 30 seconds of fixed
    setup, one second per 750 unique closure objects, and one second per
    50,000 reference/vertex records. It is used only to split exact scan
    results toward the ten-minute planning target; the runtime thirty-minute
    deadline remains authoritative and a retained calibrated model can replace
    this version only through an explicit policy update.
    """

    if not isinstance(workload, Mapping):
        raise ValueError("workload counters must be a mapping")

    def counter(name: str) -> int:
        value = workload.get(name, 0)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"workload counter {name} is invalid")
        return value

    return (
        30
        + math.ceil(counter("totalObjectCount") / 750)
        + math.ceil(counter("storedRelationMemberCount") / 50_000)
        + math.ceil(counter("wayNodeReferenceCount") / 50_000)
        + math.ceil(counter("vertexCount") / 50_000)
    )


def summarize_resource_observations(
    observations: Iterable[Mapping[str, Any]],
    *,
    minimum_observations: int = DEFAULT_MINIMUM_OBSERVATIONS,
) -> dict[str, Any]:
    """Return deterministic, conservative memory evidence by worker class.

    This report is deliberately observational. It never changes admission
    policy; a group must reach the reviewed sample count before it is marked
    calibrated, and callers can continue using conservative static estimates
    until then.
    """

    if (
        isinstance(minimum_observations, bool)
        or not isinstance(minimum_observations, int)
        or minimum_observations <= 0
    ):
        raise ValueError("minimum observations must be positive")
    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for raw in observations:
        if not isinstance(raw, Mapping):
            continue
        model_version = raw.get("resourceModelVersion", "unknown")
        if not isinstance(model_version, str) or not model_version:
            continue
        capability = raw.get("workerCapability")
        if not isinstance(capability, Mapping):
            capability = {}
        identity = _capability_identity(capability)
        actual = _nonnegative_int(raw.get("actualPeakMemoryBytes"))
        predicted = _nonnegative_int(raw.get("predictedPeakMemoryBytes"))
        if actual is None or predicted is None:
            continue
        groups[(model_version, identity)].append(
            {
                "actualPeakMemoryBytes": actual,
                "predictedPeakMemoryBytes": predicted,
                "workerCapability": _stable_capability(capability),
            }
        )

    summaries: list[dict[str, Any]] = []
    for (model_version, identity), values in sorted(groups.items()):
        actual_values = sorted(value["actualPeakMemoryBytes"] for value in values)
        predicted_values = sorted(
            value["predictedPeakMemoryBytes"] for value in values
        )
        underpredictions = sum(
            value["actualPeakMemoryBytes"] > value["predictedPeakMemoryBytes"]
            for value in values
        )
        p95_actual = _percentile95(actual_values)
        p95_predicted = _percentile95(predicted_values)
        multiplier = None
        has_positive_actual_with_zero_prediction = any(
            value["actualPeakMemoryBytes"] > 0
            and value["predictedPeakMemoryBytes"] == 0
            for value in values
        )
        if not has_positive_actual_with_zero_prediction:
            paired_ratios = sorted(
                (
                    value["actualPeakMemoryBytes"]
                    / value["predictedPeakMemoryBytes"]
                    if value["predictedPeakMemoryBytes"] > 0
                    else 1.0
                )
                for value in values
            )
            multiplier = round(max(1.0, _percentile95(paired_ratios)), 4)
        capability = values[0]["workerCapability"]
        summaries.append(
            {
                "resourceModelVersion": model_version,
                "workerCapabilityIdentitySha256": identity,
                "workerClass": capability.get("workerClass", "default"),
                "resourcePool": capability.get("resourcePool", "default"),
                "observationCount": len(values),
                "status": (
                    "calibrated"
                    if len(values) >= minimum_observations
                    and multiplier is not None
                    else "insufficient_observations"
                ),
                "minimumObservations": minimum_observations,
                "p95ActualPeakMemoryBytes": p95_actual,
                "p95PredictedPeakMemoryBytes": p95_predicted,
                "underpredictionCount": underpredictions,
                "underpredictionRate": round(underpredictions / len(values), 6),
                "conservativeMemoryMultiplier": multiplier,
            }
        )
    return {
        "schemaVersion": RESOURCE_MODEL_SCHEMA_VERSION,
        "model": "building-peak-memory-p95",
        "observationCount": sum(len(values) for values in groups.values()),
        "groups": summaries,
    }


def train_resource_model(
    observations: Iterable[Mapping[str, Any]],
    *,
    minimum_observations: int = DEFAULT_MINIMUM_OBSERVATIONS,
    safety_margin: float = 1.10,
) -> dict[str, Any]:
    """Build a reviewable calibration artifact from retained observations.

    Training is deliberately limited to a p95 actual/predicted memory ratio
    for one worker capability identity.  The result is an artifact for
    operator review; it never mutates admission policy or lowers the
    conservative counter-floor estimate.  A safety margin is recorded so a
    reviewed artifact can be applied explicitly by a later rollout.
    """

    if (
        isinstance(safety_margin, bool)
        or not isinstance(safety_margin, (int, float))
        or not math.isfinite(float(safety_margin))
        or safety_margin < 1.0
    ):
        raise ValueError("safety margin must be a finite number at least 1.0")
    summary = summarize_resource_observations(
        observations,
        minimum_observations=minimum_observations,
    )
    trained_groups: list[dict[str, Any]] = []
    for group in summary["groups"]:
        multiplier = group.get("conservativeMemoryMultiplier")
        calibrated = (
            group.get("status") == "calibrated"
            and isinstance(multiplier, (int, float))
            and not isinstance(multiplier, bool)
        )
        effective_multiplier = None
        if calibrated:
            effective_multiplier = round(
                max(1.0, float(multiplier)) * float(safety_margin),
                4,
            )
        trained_groups.append(
            {
                "resourceModelVersion": group["resourceModelVersion"],
                "workerCapabilityIdentitySha256": group[
                    "workerCapabilityIdentitySha256"
                ],
                "workerClass": group["workerClass"],
                "resourcePool": group["resourcePool"],
                "observationCount": group["observationCount"],
                "status": "trained" if calibrated else "insufficient_observations",
                "minimumObservations": group["minimumObservations"],
                "p95ActualPeakMemoryBytes": group["p95ActualPeakMemoryBytes"],
                "p95PredictedPeakMemoryBytes": group[
                    "p95PredictedPeakMemoryBytes"
                ],
                "underpredictionCount": group["underpredictionCount"],
                "underpredictionRate": group["underpredictionRate"],
                "rawMemoryMultiplier": multiplier,
                "safetyMargin": float(safety_margin),
                "effectiveMemoryMultiplier": effective_multiplier,
            }
        )
    return {
        "schemaVersion": RESOURCE_MODEL_SCHEMA_VERSION,
        "modelVersion": CALIBRATED_RESOURCE_MODEL_VERSION,
        "model": "building-peak-memory-p95",
        "sourceModel": RESOURCE_MODEL_VERSION,
        "minimumObservations": minimum_observations,
        "safetyMargin": float(safety_margin),
        "observationCount": summary["observationCount"],
        "groups": trained_groups,
    }


def apply_calibrated_memory_prediction(
    conservative_prediction_bytes: int,
    *,
    worker_capability: Mapping[str, Any],
    calibrated_model: Mapping[str, Any],
    resource_model_version: str = RESOURCE_MODEL_VERSION,
) -> int:
    """Apply one reviewed model group without reducing the safety floor."""

    if (
        isinstance(conservative_prediction_bytes, bool)
        or not isinstance(conservative_prediction_bytes, int)
        or conservative_prediction_bytes < 0
    ):
        raise ValueError("conservative prediction must be a non-negative integer")
    if not isinstance(worker_capability, Mapping) or not isinstance(
        calibrated_model, Mapping
    ):
        raise ValueError("worker capability and calibrated model are required")
    if calibrated_model.get("modelVersion") != CALIBRATED_RESOURCE_MODEL_VERSION:
        return conservative_prediction_bytes
    identity = _capability_identity(worker_capability)
    for group in calibrated_model.get("groups", ()):  # fail closed on malformed groups
        if not isinstance(group, Mapping):
            continue
        if group.get("resourceModelVersion") != resource_model_version:
            continue
        if group.get("workerCapabilityIdentitySha256") != identity:
            continue
        if group.get("status") != "trained":
            return conservative_prediction_bytes
        multiplier = group.get("effectiveMemoryMultiplier")
        if (
            isinstance(multiplier, bool)
            or not isinstance(multiplier, (int, float))
            or not math.isfinite(float(multiplier))
            or multiplier < 1.0
        ):
            return conservative_prediction_bytes
        calibrated = math.ceil(conservative_prediction_bytes * float(multiplier))
        return max(conservative_prediction_bytes, calibrated)
    return conservative_prediction_bytes


def _percentile95(values: list[int | float]) -> int | float:
    if not values:
        raise ValueError("percentile requires at least one value")
    return values[max(0, math.ceil(len(values) * 0.95) - 1)]


def _nonnegative_int(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _stable_capability(capability: Mapping[str, Any]) -> dict[str, Any]:
    stable = {
        key: capability.get(key)
        for key in (
            "schemaVersion",
            "workerClass",
            "resourcePool",
            "cpuCount",
            "memoryLimitBytes",
            "configuredMemoryLimitBytes",
            "cgroupMemoryLimitBytes",
            "maxConcurrentTasks",
        )
        if capability.get(key) is not None
    }
    return stable


def _capability_identity(capability: Mapping[str, Any]) -> str:
    reported = capability.get("identitySha256")
    if isinstance(reported, str) and _SHA256.fullmatch(reported):
        return reported
    encoded = json.dumps(
        _stable_capability(capability),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()
