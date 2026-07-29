#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
BACKEND_ROOT = REPO_ROOT / "map-platform" / "backend"
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from map_platform.map_stream_hardware_requirements import (  # noqa: E402
    HardwareRequirementsDocument,
    load_hardware_requirements,
)
from map_platform.map_stream_trust_registry import (  # noqa: E402
    FORBIDDEN_FIXTURE_KEY_IDS,
    KEY_ID_PATTERN,
    trusted_key_fingerprints,
)
from map_platform.strict_json import loads_strict_json  # noqa: E402


DEFAULT_REQUIREMENTS = REPO_ROOT / "map-platform" / "config" / "map-stream-hardware-gate.json"
DEFAULT_TRUST_REGISTRY = REPO_ROOT / "map-platform" / "config" / "map-stream-trust.json"
PROMOTION_ID_PATTERN = re.compile(r"msr-[0-9]{8}-[a-z0-9-]{4,40}")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
GIT_SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
IOS_BUILD_PATTERN = re.compile(r"[0-9]{1,18}(?:\.[0-9]{1,18}){0,2}")
TIMESTAMP_PATTERN = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,6})?Z"
)
MAXIMUM_STREAM_PAYLOAD_BYTES = 512 * 1024 * 1024
MAXIMUM_RECORDED_IO_BYTES = 4 * 1024 * 1024 * 1024
UINT32_MAX = (1 << 32) - 1
OCI_DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}")


def load_requirements(path: Path = DEFAULT_REQUIREMENTS) -> dict:
    return load_hardware_requirements(path).values


def _number(value: object, field: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{field} must be numeric")
    try:
        number = float(value)
    except (OverflowError, ValueError) as exc:
        raise ValueError(f"{field} is outside its valid range") from exc
    if not math.isfinite(number) or number < 0 or (positive and number <= 0):
        raise ValueError(f"{field} is outside its valid range")
    return number


def _integer(value: object, field: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{field} must be an integer")
    if value < 0 or (positive and value <= 0):
        raise ValueError(f"{field} is outside its valid range")
    return value


def _iso_timestamp(value: object, field: str) -> datetime:
    if not isinstance(value, str) or not TIMESTAMP_PATTERN.fullmatch(value):
        raise ValueError(f"{field} must be an ISO timestamp")
    try:
        parsed = datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError as exc:
        raise ValueError(f"{field} must be an ISO timestamp") from exc
    if parsed.tzinfo is None:
        raise ValueError(f"{field} must be an ISO timestamp")
    return parsed


def validate_report_bytes(
    report_bytes: bytes,
    requirements: dict,
    trusted_keys: dict[str, str],
) -> dict:
    report = loads_strict_json(
        report_bytes,
        description="map stream hardware report",
    )
    if not isinstance(report, dict) or set(report) != {
        "schemaVersion",
        "candidate",
        "runs",
        "approval",
    }:
        raise ValueError("map stream hardware report has invalid fields")
    if (
        type(report["schemaVersion"]) is not int
        or report["schemaVersion"] != 1
    ):
        raise ValueError("unsupported map stream hardware report schema")

    candidate = report["candidate"]
    if not isinstance(candidate, dict) or set(candidate) != {
        "gitSha",
        "producerBuildSha256",
        "workerImageDigest",
        "firmwareVersion",
        "firmwareBuild",
        "firmwareGitSha",
        "iosBuild",
        "iosGitSha",
        "iosBuildSha256",
        "signingKeys",
    }:
        raise ValueError("hardware report candidate has invalid fields")
    if not isinstance(candidate["gitSha"], str) or not GIT_SHA_PATTERN.fullmatch(
        candidate["gitSha"]
    ):
        raise ValueError("hardware report candidate git SHA is invalid")
    if (
        not isinstance(candidate["producerBuildSha256"], str)
        or not SHA256_PATTERN.fullmatch(candidate["producerBuildSha256"])
        or not isinstance(candidate["workerImageDigest"], str)
        or not OCI_DIGEST_PATTERN.fullmatch(candidate["workerImageDigest"])
    ):
        raise ValueError("hardware report candidate producer identity is invalid")
    if (
        not isinstance(candidate["firmwareVersion"], str)
        or not candidate["firmwareVersion"].strip()
        or type(candidate["firmwareBuild"]) is not int
        or not 1 <= candidate["firmwareBuild"] <= UINT32_MAX
        or not isinstance(candidate["firmwareGitSha"], str)
        or not GIT_SHA_PATTERN.fullmatch(candidate["firmwareGitSha"])
    ):
        raise ValueError("hardware report candidate firmware identity is invalid")
    if (
        not isinstance(candidate["iosBuild"], str)
        or not IOS_BUILD_PATTERN.fullmatch(candidate["iosBuild"])
        or not isinstance(candidate["iosGitSha"], str)
        or not GIT_SHA_PATTERN.fullmatch(candidate["iosGitSha"])
        or not isinstance(candidate["iosBuildSha256"], str)
        or not SHA256_PATTERN.fullmatch(candidate["iosBuildSha256"])
    ):
        raise ValueError("hardware report candidate iOS identity is invalid")
    signing_keys = candidate["signingKeys"]
    if (
        not isinstance(signing_keys, list)
        or not signing_keys
        or any(
            not isinstance(value, dict)
            or set(value) != {"keyId", "publicKeySha256"}
            or not isinstance(value["keyId"], str)
            or not KEY_ID_PATTERN.fullmatch(value["keyId"])
            or value["keyId"] in FORBIDDEN_FIXTURE_KEY_IDS
            or not isinstance(value["publicKeySha256"], str)
            or not SHA256_PATTERN.fullmatch(value["publicKeySha256"])
            for value in signing_keys
        )
    ):
        raise ValueError("hardware report signing keys are invalid")
    signing_key_ids = [value["keyId"] for value in signing_keys]
    if (
        signing_key_ids != sorted(signing_key_ids)
        or len(signing_key_ids) != len(set(signing_key_ids))
    ):
        raise ValueError("hardware report signing keys are invalid")
    if any(
        trusted_keys.get(value["keyId"]) != value["publicKeySha256"]
        for value in signing_keys
    ):
        raise ValueError(
            "hardware report uses signing material absent from production trust"
        )

    runs = report["runs"]
    if not isinstance(runs, list):
        raise ValueError("hardware report runs must be an array")
    identities: set[tuple[str, str, int]] = set()
    signing_key_targets: dict[tuple[str, str], set[str]] = {}
    recorded_times: list[datetime] = []
    for index, run in enumerate(runs):
        if not isinstance(run, dict) or set(run) != {
            "target",
            "scenario",
            "repetition",
            "recordedAt",
            "passed",
            "observed",
            "metrics",
            "assertions",
            "notes",
        }:
            raise ValueError(f"hardware run {index} has invalid fields")
        target = run["target"]
        scenario = run["scenario"]
        repetition = run["repetition"]
        if (
            not isinstance(target, str)
            or not isinstance(scenario, str)
            or target not in requirements["targets"]
            or scenario not in requirements["scenarios"]
        ):
            raise ValueError(f"hardware run {index} is outside the required matrix")
        if isinstance(repetition, bool) or not isinstance(repetition, int) or repetition < 1:
            raise ValueError(f"hardware run {index} has an invalid repetition")
        identity = (target, scenario, repetition)
        if identity in identities:
            raise ValueError(f"hardware run {index} duplicates a matrix identity")
        identities.add(identity)
        recorded_times.append(
            _iso_timestamp(run["recordedAt"], f"hardware run {index} recordedAt")
        )
        if run["passed"] is not True:
            raise ValueError(f"hardware run {index} did not pass")
        if not isinstance(run["notes"], str):
            raise ValueError(f"hardware run {index} notes must be a string")
        observed = run["observed"]
        expected_observed_fields = {
            "iosBuild",
            "iosGitSha",
            "iosBuildSha256",
            "firmwareVersion",
            "firmwareBuild",
            "firmwareGitSha",
            "artifactFormat",
            "artifactSha256",
            "producerBuildSha256",
            "producerImageDigest",
            "signatureKeyId",
            "signatureKeySha256",
            "signedManifestReceipt",
        }
        if not isinstance(observed, dict) or set(observed) != expected_observed_fields:
            raise ValueError(f"hardware run {index} observed identity has invalid fields")
        if (
            not isinstance(observed["iosBuild"], str)
            or not IOS_BUILD_PATTERN.fullmatch(observed["iosBuild"])
            or not isinstance(observed["iosGitSha"], str)
            or not GIT_SHA_PATTERN.fullmatch(observed["iosGitSha"])
            or (
                observed["iosBuildSha256"] is not None
                and (
                    not isinstance(observed["iosBuildSha256"], str)
                    or not SHA256_PATTERN.fullmatch(observed["iosBuildSha256"])
                )
            )
            or not isinstance(observed["firmwareVersion"], str)
            or not observed["firmwareVersion"].strip()
            or type(observed["firmwareBuild"]) is not int
            or not 1 <= observed["firmwareBuild"] <= UINT32_MAX
            or not isinstance(observed["firmwareGitSha"], str)
            or not GIT_SHA_PATTERN.fullmatch(observed["firmwareGitSha"])
            or not isinstance(observed["artifactSha256"], str)
            or not SHA256_PATTERN.fullmatch(observed["artifactSha256"])
        ):
            raise ValueError(f"hardware run {index} observed identity is invalid")
        observed_firmware = (
            observed["firmwareVersion"],
            observed["firmwareBuild"],
            observed["firmwareGitSha"],
        )
        candidate_firmware = (
            candidate["firmwareVersion"],
            candidate["firmwareBuild"],
            candidate["firmwareGitSha"],
        )
        if scenario == "old_app_new_firmware":
            legacy_app = requirements["legacyCompatibility"]["oldApp"]
            if (
                observed["iosBuild"] != legacy_app["iosBuild"]
                or observed["iosGitSha"] != legacy_app["iosGitSha"]
                or observed["iosBuildSha256"] is not None
                or observed_firmware != candidate_firmware
            ):
                raise ValueError(f"hardware run {index} does not exercise old-app compatibility")
        elif scenario == "new_app_old_firmware":
            legacy_firmware = requirements["legacyCompatibility"]["oldFirmware"]
            if (
                observed["iosBuild"] != candidate["iosBuild"]
                or observed["iosGitSha"] != candidate["iosGitSha"]
                or observed["iosBuildSha256"] != candidate["iosBuildSha256"]
                or observed_firmware
                != (
                    legacy_firmware["version"],
                    legacy_firmware["build"],
                    legacy_firmware["gitSha"],
                )
            ):
                raise ValueError(f"hardware run {index} does not exercise old-firmware compatibility")
        elif (
            observed["iosBuild"] != candidate["iosBuild"]
            or observed["iosGitSha"] != candidate["iosGitSha"]
            or observed["iosBuildSha256"] != candidate["iosBuildSha256"]
            or observed_firmware != candidate_firmware
        ):
            raise ValueError(f"hardware run {index} does not use the candidate app and firmware")
        compatibility_scenario = scenario in {
            "old_app_new_firmware",
            "new_app_old_firmware",
        }
        stream_identity_fields = (
            "producerBuildSha256",
            "producerImageDigest",
            "signatureKeyId",
            "signatureKeySha256",
            "signedManifestReceipt",
        )
        if not isinstance(observed["artifactFormat"], str) or any(
            observed[field] is not None and not isinstance(observed[field], str)
            for field in stream_identity_fields
        ):
            raise ValueError(f"hardware run {index} observed artifact identity is invalid")
        if compatibility_scenario:
            if observed["artifactFormat"] != "zip-stored-v1" or any(
                observed[field] is not None for field in stream_identity_fields
            ):
                raise ValueError(f"hardware run {index} did not use the ZIP fallback")
        else:
            observed_key = (
                observed["signatureKeyId"],
                observed["signatureKeySha256"],
            )
            if (
                observed["artifactFormat"] != "bike-map-stream-v1"
                or observed["producerBuildSha256"] != candidate["producerBuildSha256"]
                or observed["producerImageDigest"] != candidate["workerImageDigest"]
                or not isinstance(observed["signatureKeyId"], str)
                or not KEY_ID_PATTERN.fullmatch(observed["signatureKeyId"])
                or not isinstance(observed["signatureKeySha256"], str)
                or not SHA256_PATTERN.fullmatch(observed["signatureKeySha256"])
                or observed_key not in {
                    (value["keyId"], value["publicKeySha256"])
                    for value in signing_keys
                }
                or not isinstance(observed["signedManifestReceipt"], str)
                or not SHA256_PATTERN.fullmatch(observed["signedManifestReceipt"])
            ):
                raise ValueError(f"hardware run {index} did not use the candidate stream artifact")
            signing_key_targets.setdefault(observed_key, set()).add(target)
        metrics = run["metrics"]
        required_metrics = set(requirements["requiredMetrics"])
        shanghai_metrics = {
            "v1MaxTemperatureC",
            "v1PayloadBytesWritten",
            "v1PostTransferSeconds",
        }
        expected_metrics = required_metrics | (
            shanghai_metrics if scenario == "shanghai_clean_install" else set()
        )
        if not isinstance(metrics, dict) or set(metrics) != expected_metrics:
            raise ValueError(f"hardware run {index} metrics do not match the schema")
        byte_metrics = {
            "durableBytesRewritten",
            "payloadBytes",
            "payloadBytesWritten",
            "retryBytesSkipped",
            "v1PayloadBytesWritten",
        }
        numeric = {
            name: (
                _integer(
                    value,
                    f"hardware run {index} metric {name}",
                    positive=name == "payloadBytes",
                )
                if name in byte_metrics
                else _number(
                    value,
                    f"hardware run {index} metric {name}",
                    positive=name == "maxTemperatureC",
                )
            )
            for name, value in metrics.items()
        }
        if numeric["payloadBytes"] > MAXIMUM_STREAM_PAYLOAD_BYTES or any(
            numeric[name] > MAXIMUM_RECORDED_IO_BYTES
            for name in byte_metrics
            if name in numeric
        ):
            raise ValueError(f"hardware run {index} byte metric exceeds protocol bounds")
        if numeric["maxTemperatureC"] > requirements[
            "maximumTemperatureCByTarget"
        ][target]:
            raise ValueError(f"hardware run {index} exceeds the thermal limit")
        if numeric["durableBytesRewritten"] != 0:
            raise ValueError(f"hardware run {index} rewrote durable checkpointed bytes")
        if scenario in requirements["exactSingleWriteScenarios"] and (
            numeric["payloadBytesWritten"] != numeric["payloadBytes"]
        ):
            raise ValueError(f"hardware run {index} did not perform one clean payload write")
        if numeric["retryBytesSkipped"] > numeric["payloadBytes"]:
            raise ValueError(f"hardware run {index} skipped more than the payload")
        if not compatibility_scenario and numeric["payloadBytesWritten"] > (
            numeric["payloadBytes"]
            + requirements["maximumResumeWriteAmplificationBytes"]
        ):
            raise ValueError(
                f"hardware run {index} exceeds the payload write-amplification bound"
            )
        if scenario in requirements["boundedResumeScenarios"] and (
            numeric["payloadBytesWritten"] < numeric["payloadBytes"]
        ):
            raise ValueError(
                f"hardware run {index} did not complete its resumed payload write"
            )
        if (
            scenario in requirements["requiredRetrySkipScenarios"]
            and numeric["retryBytesSkipped"] <= 0
        ):
            raise ValueError(f"hardware run {index} did not resume a durable prefix")
        assertions = run["assertions"]
        if (
            not isinstance(assertions, dict)
            or set(assertions) != set(requirements["requiredAssertions"])
            or any(value is not True for value in assertions.values())
        ):
            raise ValueError(f"hardware run {index} has an unmet assertion")
        if scenario == "shanghai_clean_install":
            current_post = numeric["step2Seconds"] + numeric["step3Seconds"]
            baseline_post = numeric["v1PostTransferSeconds"]
            if baseline_post <= 0:
                raise ValueError("Shanghai baseline post-transfer time must be positive")
            post_reduction = (baseline_post - current_post) / baseline_post * 100
            if post_reduction < requirements[
                "minimumShanghaiPostTransferReductionPercent"
            ]:
                raise ValueError(f"hardware run {index} misses the time reduction gate")
            baseline_writes = numeric["v1PayloadBytesWritten"]
            if baseline_writes <= 0:
                raise ValueError("Shanghai baseline SD writes must be positive")
            write_reduction = (
                (baseline_writes - numeric["payloadBytesWritten"])
                / baseline_writes
                * 100
            )
            if write_reduction < requirements[
                "minimumShanghaiSdWriteReductionPercent"
            ]:
                raise ValueError(f"hardware run {index} misses the SD-write gate")
            if numeric["maxTemperatureC"] > (
                numeric["v1MaxTemperatureC"]
                + requirements["maximumShanghaiTemperatureRegressionC"]
            ):
                raise ValueError(f"hardware run {index} misses the thermal comparison gate")
    for target in requirements["targets"]:
        for scenario, repetitions in requirements["scenarios"].items():
            expected_identities = {
                (target, scenario, repetition)
                for repetition in range(1, repetitions + 1)
            }
            actual_identities = {
                identity
                for identity in identities
                if identity[0] == target and identity[1] == scenario
            }
            if actual_identities != expected_identities:
                raise ValueError(
                    f"hardware report does not exactly cover {target} {scenario} repetitions"
                )
    required_targets = set(requirements["targets"])
    for signing_key in signing_keys:
        key = (signing_key["keyId"], signing_key["publicKeySha256"])
        if signing_key_targets.get(key, set()) != required_targets:
            raise ValueError(
                f"hardware report did not exercise signing key {signing_key['keyId']} on both targets"
            )

    approval = report["approval"]
    if not isinstance(approval, dict) or set(approval) != {
        "approved",
        "approvedAt",
        "approvedBy",
        "notes",
    }:
        raise ValueError("hardware report approval has invalid fields")
    if approval["approved"] is not True:
        raise ValueError("hardware report is not approved")
    approved_at = _iso_timestamp(
        approval["approvedAt"],
        "hardware report approvedAt",
    )
    if recorded_times and approved_at <= max(recorded_times):
        raise ValueError("hardware report approval does not follow every recorded run")
    if not isinstance(approval["approvedBy"], str) or not approval["approvedBy"].strip():
        raise ValueError("hardware report approvedBy is required")
    if not isinstance(approval["notes"], str):
        raise ValueError("hardware report approval notes must be a string")
    return report


def validate_report(
    report_path: Path,
    requirements: dict,
    trusted_keys: dict[str, str],
) -> dict:
    try:
        report_bytes = report_path.read_bytes()
    except OSError as exc:
        raise ValueError(f"map stream hardware report is unreadable: {exc}") from exc
    return validate_report_bytes(report_bytes, requirements, trusted_keys)


def approval_record(
    report_bytes: bytes,
    report: dict,
    promotion_id: str,
    requirements: HardwareRequirementsDocument,
    trusted_signing_keys: dict[str, str],
) -> dict:
    if not PROMOTION_ID_PATTERN.fullmatch(promotion_id):
        raise ValueError("promotion ID has an invalid format")
    signing_keys = report["candidate"]["signingKeys"]
    if any(
        trusted_signing_keys.get(value["keyId"])
        != value["publicKeySha256"]
        for value in signing_keys
    ):
        raise ValueError(
            "hardware report uses signing material absent from production trust"
        )
    return {
        "promotionId": promotion_id,
        "candidateGitSha": report["candidate"]["gitSha"],
        "producerBuildSha256": report["candidate"]["producerBuildSha256"],
        "workerImageDigest": report["candidate"]["workerImageDigest"],
        "firmwareVersion": report["candidate"]["firmwareVersion"],
        "firmwareBuild": report["candidate"]["firmwareBuild"],
        "firmwareGitSha": report["candidate"]["firmwareGitSha"],
        "iosBuild": report["candidate"]["iosBuild"],
        "iosGitSha": report["candidate"]["iosGitSha"],
        "iosBuildSha256": report["candidate"]["iosBuildSha256"],
        "reportSha256": hashlib.sha256(report_bytes).hexdigest(),
        "requirementsSha256": requirements.sha256,
        "approvedAt": report["approval"]["approvedAt"],
        "approvedBy": report["approval"]["approvedBy"],
        "targets": requirements.values["targets"],
        "signingKeys": [dict(value) for value in signing_keys],
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate the map-stream real-device promotion gate."
    )
    parser.add_argument("--requirements", type=Path, default=DEFAULT_REQUIREMENTS)
    parser.add_argument("--trust-registry", type=Path, default=DEFAULT_TRUST_REGISTRY)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--validate-requirements", action="store_true")
    action.add_argument("--check-report", type=Path)
    parser.add_argument("--promotion-id")
    args = parser.parse_args()
    try:
        requirements_document = load_hardware_requirements(args.requirements)
        if args.validate_requirements:
            if args.promotion_id:
                raise ValueError("promotion ID is only valid with --check-report")
            return 0
        if not args.promotion_id:
            raise ValueError("--promotion-id is required with --check-report")
        try:
            report_bytes = args.check_report.read_bytes()
        except OSError as exc:
            raise ValueError(f"map stream hardware report is unreadable: {exc}") from exc
        trusted_signing_keys = trusted_key_fingerprints(args.trust_registry)
        report = validate_report_bytes(
            report_bytes,
            requirements_document.values,
            trusted_signing_keys,
        )
        print(
            json.dumps(
                approval_record(
                    report_bytes,
                    report,
                    args.promotion_id,
                    requirements_document,
                    trusted_signing_keys,
                ),
                indent=2,
                sort_keys=False,
            )
        )
        return 0
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
