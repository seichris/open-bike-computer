from __future__ import annotations

import hashlib
import math
import re
from dataclasses import dataclass
from pathlib import Path

from .strict_json import loads_strict_json


PRODUCTION_TARGETS = (
    "WAVESHARE_AMOLED_175",
    "WAVESHARE_AMOLED_206",
)
GIT_SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
IOS_BUILD_PATTERN = re.compile(r"[0-9]{1,18}(?:\.[0-9]{1,18}){0,2}")
UINT32_MAX = (1 << 32) - 1
MAXIMUM_SCENARIO_REPETITIONS = 10


@dataclass(frozen=True)
class HardwareRequirementsDocument:
    values: dict
    sha256: str


def _finite_number(value: object, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{field} must be numeric")
    try:
        number = float(value)
    except (OverflowError, ValueError) as exc:
        raise ValueError(f"{field} must be finite") from exc
    if not math.isfinite(number):
        raise ValueError(f"{field} must be finite")
    return number


def parse_hardware_requirements(data: bytes) -> HardwareRequirementsDocument:
    document = loads_strict_json(
        data,
        description="map stream hardware requirements",
    )
    expected_fields = {
        "schemaVersion",
        "targets",
        "scenarios",
        "boundedResumeScenarios",
        "exactSingleWriteScenarios",
        "requiredRetrySkipScenarios",
        "legacyCompatibility",
        "requiredAssertions",
        "requiredMetrics",
        "maximumResumeWriteAmplificationBytes",
        "minimumShanghaiPostTransferReductionPercent",
        "minimumShanghaiSdWriteReductionPercent",
        "maximumShanghaiTemperatureRegressionC",
        "maximumTemperatureCByTarget",
    }
    if not isinstance(document, dict) or set(document) != expected_fields:
        raise ValueError("map stream hardware requirements have invalid fields")
    if (
        type(document["schemaVersion"]) is not int
        or document["schemaVersion"] != 1
    ):
        raise ValueError("unsupported map stream hardware requirements schema")
    if document["targets"] != list(PRODUCTION_TARGETS):
        raise ValueError("hardware requirements must cover both production targets")
    scenarios = document["scenarios"]
    if (
        not isinstance(scenarios, dict)
        or not scenarios
        or list(scenarios) != sorted(scenarios)
        or any(
            not isinstance(name, str)
            or not re.fullmatch(r"[a-z0-9_]{3,64}", name)
            or isinstance(repetitions, bool)
            or not isinstance(repetitions, int)
            or not 1 <= repetitions <= MAXIMUM_SCENARIO_REPETITIONS
            for name, repetitions in scenarios.items()
        )
    ):
        raise ValueError(
            "hardware scenarios must be sorted bounded positive requirements"
        )
    for field in (
        "boundedResumeScenarios",
        "exactSingleWriteScenarios",
        "requiredRetrySkipScenarios",
    ):
        values = document[field]
        if (
            not isinstance(values, list)
            or values != sorted(values)
            or len(values) != len(set(values))
            or any(value not in scenarios for value in values)
        ):
            raise ValueError(f"{field} must be a sorted scenario subset")
    if not set(document["requiredRetrySkipScenarios"]).issubset(
        document["boundedResumeScenarios"]
    ):
        raise ValueError("retry-skip scenarios must be bounded resume scenarios")
    compatibility = document["legacyCompatibility"]
    if not isinstance(compatibility, dict) or set(compatibility) != {
        "oldApp",
        "oldFirmware",
    }:
        raise ValueError("legacy compatibility requirements are invalid")
    old_app = compatibility["oldApp"]
    old_firmware = compatibility["oldFirmware"]
    if (
        not isinstance(old_app, dict)
        or set(old_app) != {"iosBuild", "iosGitSha"}
        or not isinstance(old_app["iosBuild"], str)
        or not IOS_BUILD_PATTERN.fullmatch(old_app["iosBuild"])
        or not isinstance(old_app["iosGitSha"], str)
        or not GIT_SHA_PATTERN.fullmatch(old_app["iosGitSha"])
    ):
        raise ValueError("legacy app identity is invalid")
    if (
        not isinstance(old_firmware, dict)
        or set(old_firmware) != {"version", "build", "gitSha"}
        or not isinstance(old_firmware["version"], str)
        or not old_firmware["version"].strip()
        or type(old_firmware["build"]) is not int
        or not 1 <= old_firmware["build"] <= UINT32_MAX
        or not isinstance(old_firmware["gitSha"], str)
        or not GIT_SHA_PATTERN.fullmatch(old_firmware["gitSha"])
    ):
        raise ValueError("legacy firmware identity is invalid")
    for field in ("requiredAssertions", "requiredMetrics"):
        values = document[field]
        if (
            not isinstance(values, list)
            or not values
            or values != sorted(values)
            or len(values) != len(set(values))
            or any(not isinstance(value, str) or not value for value in values)
        ):
            raise ValueError(f"{field} must be a sorted unique string array")
    for field in (
        "minimumShanghaiPostTransferReductionPercent",
        "minimumShanghaiSdWriteReductionPercent",
    ):
        value = _finite_number(document[field], field)
        if not 0 < value < 100:
            raise ValueError(f"{field} must be between 0 and 100")
    maximum_write_amplification = document[
        "maximumResumeWriteAmplificationBytes"
    ]
    if (
        type(maximum_write_amplification) is not int
        or not 1 <= maximum_write_amplification <= 16 * 1024 * 1024
    ):
        raise ValueError("maximum resume write amplification is invalid")
    thermal_regression = _finite_number(
        document["maximumShanghaiTemperatureRegressionC"],
        "maximumShanghaiTemperatureRegressionC",
    )
    if not 0 <= thermal_regression <= 10:
        raise ValueError("maximum Shanghai temperature regression is invalid")
    absolute_limits = document["maximumTemperatureCByTarget"]
    if (
        not isinstance(absolute_limits, dict)
        or list(absolute_limits) != list(PRODUCTION_TARGETS)
    ):
        raise ValueError("absolute thermal limits must cover both production targets")
    for target, raw_limit in absolute_limits.items():
        limit = _finite_number(raw_limit, f"maximumTemperatureCByTarget.{target}")
        if not 30 <= limit <= 85:
            raise ValueError(f"absolute thermal limit for {target} is invalid")
    return HardwareRequirementsDocument(
        values=document,
        sha256=hashlib.sha256(data).hexdigest(),
    )


def load_hardware_requirements(path: Path) -> HardwareRequirementsDocument:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise ValueError(f"map stream hardware requirements are unreadable: {exc}") from exc
    return parse_hardware_requirements(data)
