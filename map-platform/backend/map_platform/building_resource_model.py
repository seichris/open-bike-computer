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
_SHA256 = re.compile(r"[0-9a-f]{64}")


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
        if p95_predicted > 0:
            multiplier = round(max(1.0, p95_actual / p95_predicted), 4)
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


def _percentile95(values: list[int]) -> int:
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
