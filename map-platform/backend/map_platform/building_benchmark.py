"""Validation contract for retained target-3 selected-area benchmark evidence."""

from __future__ import annotations

from copy import deepcopy
import re
from typing import Any


class BuildingBenchmarkError(ValueError):
    """Raised when a benchmark run does not satisfy the reviewed gate."""


REQUIRED_RUNS = (
    "legacyCold",
    "legacyWarm",
    "selectedCold",
    "selectedWarm",
)
_SHA256 = re.compile(r"[0-9a-f]{64}")


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise BuildingBenchmarkError(message)


def _integer(value: Any, label: str) -> int:
    _require(
        isinstance(value, int) and not isinstance(value, bool) and value >= 0,
        f"{label} must be a nonnegative integer",
    )
    return value


def _mapping(value: Any, label: str) -> dict[str, Any]:
    _require(isinstance(value, dict), f"{label} must be an object")
    return value


def _calibration(run: dict[str, Any]) -> dict[str, Any]:
    preprocessing = _mapping(
        run.get("artifactMetrics", {}).get("buildingPreprocessing"),
        "selected building preprocessing",
    )
    return _mapping(preprocessing.get("calibration"), "selected calibration")


def _cache_outcome(run: dict[str, Any]) -> str:
    preprocessing = _mapping(
        run.get("artifactMetrics", {}).get("buildingPreprocessing"),
        "selected building preprocessing",
    )
    for key in ("calibrationGenerationExecution", "calibrationExecution"):
        execution = preprocessing.get(key)
        if isinstance(execution, dict) and isinstance(
            execution.get("cacheOutcome"), str
        ):
            return execution["cacheOutcome"]
    raise BuildingBenchmarkError("selected calibration cache outcome is missing")


def _stream_receipt(run: dict[str, Any]) -> tuple[str, str]:
    artifacts = run.get("artifacts")
    _require(isinstance(artifacts, list), "benchmark artifacts must be a list")
    for artifact in artifacts:
        if isinstance(artifact, dict) and artifact.get("format") == "bike-map-stream-v1":
            manifest = artifact.get("manifestReceipt")
            signed = artifact.get("signedManifestReceipt")
            _require(
                isinstance(manifest, str) and _SHA256.fullmatch(manifest) is not None,
                "map stream manifest receipt is missing",
            )
            _require(
                isinstance(signed, str) and _SHA256.fullmatch(signed) is not None,
                "map stream signed receipt is missing",
            )
            return manifest, signed
    raise BuildingBenchmarkError("map stream artifact is missing")


def validate_benchmark_evidence(
    fixture: dict[str, Any], runs: dict[str, Any]
) -> dict[str, Any]:
    """Validate full-run evidence and return a canonical review summary."""
    expected = _mapping(fixture.get("expected"), "benchmark expected values")
    _require(set(runs) == set(REQUIRED_RUNS), "benchmark run set is incomplete")
    normalized = {
        name: _mapping(deepcopy(runs[name]), f"benchmark run {name}")
        for name in REQUIRED_RUNS
    }
    source_identities = [
        _mapping(run.get("sourceIdentity"), "benchmark source identity")
        for run in normalized.values()
    ]
    _require(
        all(identity == source_identities[0] for identity in source_identities[1:]),
        "benchmark runs do not use one pinned source snapshot",
    )
    worker_identities = [
        _mapping(run.get("workerIdentity"), "benchmark worker identity")
        for run in normalized.values()
    ]
    _require(
        all(identity == worker_identities[0] for identity in worker_identities[1:]),
        "benchmark runs do not use one worker identity",
    )
    for name, run in normalized.items():
        _integer(run.get("peakResidentBytes"), f"{name} peak resident bytes")
        _integer(run.get("sourceQueryBytes"), f"{name} source query bytes")
        counts = _mapping(run.get("sourceQueryObjects"), f"{name} source objects")
        for object_type in ("nodes", "ways", "relations"):
            _integer(counts.get(object_type), f"{name} {object_type}")
        timings = _mapping(run.get("timings"), f"{name} timings")
        for timing in (
            "wallMilliseconds",
            "firstPreprocessingProgressMilliseconds",
            "firstBlockProgressMilliseconds",
        ):
            _integer(timings.get(timing), f"{name} {timing}")
        hashes = _mapping(run.get("fmbSha256ByPath"), f"{name} FMB hashes")
        _require(bool(hashes), f"{name} emitted no FMB blocks")
        _stream_receipt(run)

    legacy_hashes = normalized["legacyWarm"]["fmbSha256ByPath"]
    selected_hashes = normalized["selectedWarm"]["fmbSha256ByPath"]
    _require(
        normalized["legacyCold"]["fmbSha256ByPath"] == legacy_hashes,
        "legacy FMB bytes changed between cold and warm runs",
    )
    _require(
        normalized["selectedCold"]["fmbSha256ByPath"] == selected_hashes,
        "selected FMB bytes changed between cold and warm runs",
    )
    _require(
        set(selected_hashes) == set(legacy_hashes),
        "selected FMB block paths differ from the legacy reference",
    )

    selected_preprocessing = _mapping(
        normalized["selectedWarm"]["artifactMetrics"].get(
            "buildingPreprocessing"
        ),
        "selected preprocessing",
    )
    selected_scope = _mapping(selected_preprocessing.get("scope"), "selected scope")
    requested_area = _integer(
        selected_scope.get("requestedApproximateAreaM2"), "requested area"
    )
    output_area = _integer(selected_scope.get("outputAreaM2"), "output area")
    source_area = _integer(selected_scope.get("sourceAreaM2"), "source area")
    source_ratio = _integer(
        selected_scope.get("sourceToOutputAreaBasisPoints"), "source ratio"
    )
    _require(
        requested_area == _integer(
            expected.get("requestedApproximateAreaM2"), "expected requested area"
        ),
        "requested benchmark area changed",
    )
    _require(
        output_area == _integer(expected.get("outputAreaM2"), "expected output area"),
        "aligned benchmark output area changed",
    )
    _require(
        source_area == _integer(
            expected.get("newSourceAreaM2"), "expected selected source area"
        ),
        "selected benchmark source area changed",
    )
    _require(
        source_area <= 200_000_000
        and source_ratio
        <= _integer(
            expected.get("maximumSourceToOutputAreaBasisPoints"),
            "maximum source ratio",
        ),
        "selected source scope exceeds the proposed area gate",
    )
    legacy_area = _integer(
        expected.get("legacySourceAreaM2"), "legacy source area"
    )
    reduction_basis_points = (legacy_area - source_area) * 10_000 // legacy_area
    _require(
        reduction_basis_points
        >= _integer(
            expected.get("minimumLegacyReductionBasisPoints"),
            "minimum source reduction",
        ),
        "selected source scope does not meet the reduction gate",
    )

    cold_outcome = _cache_outcome(normalized["selectedCold"])
    warm_outcome = _cache_outcome(normalized["selectedWarm"])
    _require(cold_outcome != "hit", "cold selected benchmark unexpectedly hit cache")
    _require(warm_outcome == "hit", "warm selected benchmark did not hit cache")
    cold_calibration = _calibration(normalized["selectedCold"])
    warm_calibration = _calibration(normalized["selectedWarm"])
    for key in ("calibrationKey", "manifestSha256", "entrySetSha256"):
        _require(
            cold_calibration.get(key) == warm_calibration.get(key),
            f"selected calibration {key} changed across cache reuse",
        )

    selected_timings = normalized["selectedWarm"]["timings"]
    legacy_timings = normalized["legacyWarm"]["timings"]
    _require(
        selected_timings["firstPreprocessingProgressMilliseconds"] <= 10_000,
        "selected time to first preprocessing progress exceeds 10 seconds",
    )
    _require(
        selected_timings["firstBlockProgressMilliseconds"] * 2
        <= legacy_timings["firstBlockProgressMilliseconds"],
        "selected time to first block progress is not at least 50 percent lower",
    )

    receipts = {
        name: {
            "manifestReceipt": _stream_receipt(run)[0],
            "signedManifestReceipt": _stream_receipt(run)[1],
        }
        for name, run in normalized.items()
    }
    legacy_query_bytes = normalized["legacyWarm"]["sourceQueryBytes"]
    selected_query_bytes = normalized["selectedWarm"]["sourceQueryBytes"]
    query_reduction_basis_points = (
        (legacy_query_bytes - selected_query_bytes) * 10_000 // legacy_query_bytes
        if legacy_query_bytes
        else 0
    )
    return {
        "schemaVersion": 1,
        "status": "pass",
        "sourceIdentity": source_identities[0],
        "workerIdentity": worker_identities[0],
        "measurements": {
            "requestedAreaM2": requested_area,
            "outputAreaM2": output_area,
            "legacySourceAreaM2": legacy_area,
            "selectedSourceAreaM2": source_area,
            "sourceReductionBasisPoints": reduction_basis_points,
            "selectedSourceToOutputAreaBasisPoints": source_ratio,
            "legacyWarmFirstBlockProgressMilliseconds": legacy_timings[
                "firstBlockProgressMilliseconds"
            ],
            "selectedWarmFirstBlockProgressMilliseconds": selected_timings[
                "firstBlockProgressMilliseconds"
            ],
            "selectedWarmFirstPreprocessingProgressMilliseconds": selected_timings[
                "firstPreprocessingProgressMilliseconds"
            ],
            "legacyWarmSourceQueryBytes": legacy_query_bytes,
            "selectedWarmSourceQueryBytes": selected_query_bytes,
            "sourceQueryByteReductionBasisPoints": query_reduction_basis_points,
            "legacyColdPeakResidentBytes": normalized["legacyCold"][
                "peakResidentBytes"
            ],
            "legacyWarmPeakResidentBytes": normalized["legacyWarm"][
                "peakResidentBytes"
            ],
            "selectedColdPeakResidentBytes": normalized["selectedCold"][
                "peakResidentBytes"
            ],
            "selectedWarmPeakResidentBytes": normalized["selectedWarm"][
                "peakResidentBytes"
            ],
            "legacyColdWallMilliseconds": normalized["legacyCold"]["timings"][
                "wallMilliseconds"
            ],
            "legacyWarmWallMilliseconds": normalized["legacyWarm"]["timings"][
                "wallMilliseconds"
            ],
            "selectedColdWallMilliseconds": normalized["selectedCold"]["timings"][
                "wallMilliseconds"
            ],
            "selectedWarmWallMilliseconds": normalized["selectedWarm"]["timings"][
                "wallMilliseconds"
            ],
        },
        "proposedThresholds": {
            "maximumSourceAreaM2": 200_000_000,
            "maximumSourceToOutputAreaBasisPoints": _integer(
                expected.get("maximumSourceToOutputAreaBasisPoints"),
                "maximum source ratio",
            ),
            "minimumLegacySourceReductionBasisPoints": _integer(
                expected.get("minimumLegacyReductionBasisPoints"),
                "minimum source reduction",
            ),
            "maximumFirstPreprocessingProgressMilliseconds": 10_000,
            "minimumFirstBlockImprovementBasisPoints": 5_000,
        },
        "cache": {"coldOutcome": cold_outcome, "warmOutcome": warm_outcome},
        "artifactReceipts": receipts,
        "runs": normalized,
    }
