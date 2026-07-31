from __future__ import annotations

import hashlib
import hmac
import os
import re
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path

from .installations import INSTALLATION_ID_PREFIX
from .map_stream_trust_registry import (
    FORBIDDEN_FIXTURE_KEY_IDS,
    KEY_ID_PATTERN,
)
from .strict_json import load_strict_json


ROLLOUT_DOMAIN = b"open-bike-map-stream-rollout-v1\0"
ROLLOUT_BUCKETS = 10_000
INSTALLATION_ID_PATTERN = re.compile(
    rf"{re.escape(INSTALLATION_ID_PREFIX)}[0-9a-f]{{32}}"
)
PROMOTION_ID_PATTERN = re.compile(r"msr-[0-9]{8}-[a-z0-9-]{4,40}")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
OCI_DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}")
PINNED_IMAGE_PATTERN = re.compile(r"[^@\s]+@(sha256:[0-9a-f]{64})")
GIT_SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
TIMESTAMP_PATTERN = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,6})?Z"
)
IOS_BUILD_PATTERN = re.compile(r"[0-9]{1,18}(?:\.[0-9]{1,18}){0,2}")
UINT32_MAX = (1 << 32) - 1


class MapStreamRolloutMode(str, Enum):
    DISABLED = "disabled"
    ALLOWLIST = "allowlist"
    PERCENTAGE = "percentage"
    ALL = "all"


def configured_map_stream_rollout_mode() -> MapStreamRolloutMode:
    raw_mode = os.environ.get(
        "MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE",
        MapStreamRolloutMode.DISABLED.value,
    ).strip().lower()
    try:
        return MapStreamRolloutMode(raw_mode)
    except ValueError as exc:
        allowed = ", ".join(value.value for value in MapStreamRolloutMode)
        raise ValueError(
            f"MAP_PLATFORM_MAP_STREAM_ROLLOUT_MODE must be one of: {allowed}"
        ) from exc


def parse_map_stream_trust_capabilities(
    value: str | None,
) -> frozenset[tuple[str, str]]:
    if value is None or value == "":
        return frozenset()
    if len(value) > 1024:
        raise ValueError("map stream trust capability header is too large")
    capabilities: list[tuple[str, str]] = []
    for item in value.split(","):
        fields = item.split("=", 1)
        if (
            len(fields) != 2
            or not KEY_ID_PATTERN.fullmatch(fields[0])
            or fields[0] in FORBIDDEN_FIXTURE_KEY_IDS
            or not SHA256_PATTERN.fullmatch(fields[1])
        ):
            raise ValueError("map stream trust capability header is invalid")
        capabilities.append((fields[0], fields[1]))
    if (
        len(capabilities) > 4
        or len(capabilities) != len(set(capabilities))
        or len({key_id for key_id, _ in capabilities}) != len(capabilities)
    ):
        raise ValueError("map stream trust capability header is invalid")
    return frozenset(capabilities)


def parse_map_stream_app_build(value: str | None) -> str | None:
    if value is None or value == "":
        return None
    if not IOS_BUILD_PATTERN.fullmatch(value):
        raise ValueError("map stream app build header is invalid")
    return value


def parse_map_stream_app_git_sha(value: str | None) -> str | None:
    if value is None or value == "":
        return None
    if not GIT_SHA_PATTERN.fullmatch(value):
        raise ValueError("map stream app git SHA header is invalid")
    return value


def parse_map_stream_app_build_sha256(value: str | None) -> str | None:
    if value is None or value == "":
        return None
    if not SHA256_PATTERN.fullmatch(value):
        raise ValueError("map stream app build SHA-256 header is invalid")
    return value


@dataclass(frozen=True)
class MapStreamPromotionApproval:
    promotion_id: str
    candidate_git_sha: str
    producer_build_sha256: str
    worker_image_digest: str
    firmware_version: str
    firmware_build: int
    firmware_git_sha: str
    ios_build: str
    ios_git_sha: str
    ios_build_sha256: str
    report_sha256: str
    requirements_sha256: str
    approved_signing_keys: frozenset[tuple[str, str]]


@dataclass(frozen=True)
class MapStreamRolloutPolicy:
    mode: MapStreamRolloutMode
    allowlist: frozenset[str] = frozenset()
    basis_points: int = 0
    cohort_secret: bytes = field(default=b"", repr=False)
    promotion_id: str | None = None
    candidate_git_sha: str | None = None
    producer_build_sha256: str | None = None
    worker_image_digest: str | None = None
    required_firmware_version: str | None = None
    required_firmware_build: int | None = None
    required_firmware_git_sha: str | None = None
    required_ios_build: str | None = None
    required_ios_git_sha: str | None = None
    required_ios_build_sha256: str | None = None
    report_sha256: str | None = None
    requirements_sha256: str | None = None
    approved_signing_keys: frozenset[tuple[str, str]] = frozenset()

    @classmethod
    def from_environment(
        cls,
        *,
        approved_promotions_by_id: dict[str, MapStreamPromotionApproval] | None = None,
        trusted_signing_keys: dict[str, str] | None = None,
        current_requirements_sha256: str | None = None,
    ) -> "MapStreamRolloutPolicy":
        mode = configured_map_stream_rollout_mode()

        raw_allowlist = os.environ.get(
            "MAP_PLATFORM_MAP_STREAM_ROLLOUT_ALLOWLIST",
            "",
        )
        allowlist_values = [value.strip() for value in raw_allowlist.split(",") if value.strip()]
        if len(allowlist_values) != len(set(allowlist_values)):
            raise ValueError("map stream rollout allowlist contains duplicates")
        if any(not INSTALLATION_ID_PATTERN.fullmatch(value) for value in allowlist_values):
            raise ValueError("map stream rollout allowlist contains an invalid installation ID")

        raw_basis_points = os.environ.get(
            "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS",
            "0",
        ).strip()
        try:
            basis_points = int(raw_basis_points)
        except ValueError as exc:
            raise ValueError(
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS must be an integer"
            ) from exc
        if not 0 <= basis_points <= ROLLOUT_BUCKETS:
            raise ValueError(
                "MAP_PLATFORM_MAP_STREAM_ROLLOUT_BASIS_POINTS must be between 0 and 10000"
            )

        cohort_secret = os.environ.get(
            "MAP_PLATFORM_MAP_STREAM_ROLLOUT_SECRET",
            "",
        ).encode("utf-8")
        promotion_id = os.environ.get(
            "MAP_PLATFORM_MAP_STREAM_PROMOTION_ID",
            "",
        ).strip()
        worker_image_reference = os.environ.get(
            "MAP_PLATFORM_WORKER_IMAGE_REFERENCE",
            "",
        ).strip()
        approval: MapStreamPromotionApproval | None = None
        approved_keys: frozenset[tuple[str, str]] = frozenset()
        if mode == MapStreamRolloutMode.ALLOWLIST and not allowlist_values:
            raise ValueError("allowlist rollout mode requires at least one installation ID")
        if mode == MapStreamRolloutMode.PERCENTAGE:
            if not 1 <= basis_points < ROLLOUT_BUCKETS:
                raise ValueError(
                    "percentage rollout mode requires basis points between 1 and 9999"
                )
            if len(cohort_secret) < 32:
                raise ValueError(
                    "percentage rollout mode requires a cohort secret of at least 32 bytes"
                )
        elif basis_points != 0:
            raise ValueError("rollout basis points are only valid in percentage mode")
        if mode != MapStreamRolloutMode.ALLOWLIST and allowlist_values:
            raise ValueError("rollout allowlist is only valid in allowlist mode")
        if mode != MapStreamRolloutMode.PERCENTAGE and cohort_secret:
            raise ValueError("rollout cohort secret is only valid in percentage mode")
        if mode in {MapStreamRolloutMode.PERCENTAGE, MapStreamRolloutMode.ALL}:
            if not PROMOTION_ID_PATTERN.fullmatch(promotion_id):
                raise ValueError("percentage and all rollout modes require a promotion ID")
            approval = (approved_promotions_by_id or {}).get(promotion_id)
            if approval is None:
                raise ValueError("map stream rollout promotion ID is not approved")
            image_match = PINNED_IMAGE_PATTERN.fullmatch(worker_image_reference)
            if image_match is None or image_match.group(1) != approval.worker_image_digest:
                raise ValueError(
                    "promoted rollout requires the exact approved digest-pinned worker image"
                )
            if (
                current_requirements_sha256 is None
                or current_requirements_sha256 != approval.requirements_sha256
            ):
                raise ValueError(
                    "map stream rollout requirements do not match the hardware approval"
                )
            current_keys = frozenset((trusted_signing_keys or {}).items())
            if not approval.approved_signing_keys.issubset(current_keys):
                raise ValueError(
                    "map stream rollout approval uses signing material absent from production trust"
                )
            approved_keys = approval.approved_signing_keys
        elif promotion_id:
            raise ValueError(
                "rollout promotion ID is only valid in percentage or all mode"
            )

        return cls(
            mode=mode,
            allowlist=frozenset(allowlist_values),
            basis_points=basis_points,
            cohort_secret=cohort_secret,
            promotion_id=promotion_id or None,
            candidate_git_sha=approval.candidate_git_sha if approval else None,
            producer_build_sha256=(approval.producer_build_sha256 if approval else None),
            worker_image_digest=(approval.worker_image_digest if approval else None),
            required_firmware_version=(approval.firmware_version if approval else None),
            required_firmware_build=(approval.firmware_build if approval else None),
            required_firmware_git_sha=(approval.firmware_git_sha if approval else None),
            required_ios_build=(approval.ios_build if approval else None),
            required_ios_git_sha=(approval.ios_git_sha if approval else None),
            required_ios_build_sha256=(approval.ios_build_sha256 if approval else None),
            report_sha256=approval.report_sha256 if approval else None,
            requirements_sha256=approval.requirements_sha256 if approval else None,
            approved_signing_keys=approved_keys if promotion_id else frozenset(),
        )

    def includes(self, installation_id: str | None) -> bool:
        if not installation_id or not INSTALLATION_ID_PATTERN.fullmatch(installation_id):
            return False
        if self.mode == MapStreamRolloutMode.DISABLED:
            return False
        if self.mode == MapStreamRolloutMode.ALL:
            return True
        if self.mode == MapStreamRolloutMode.ALLOWLIST:
            return installation_id in self.allowlist
        digest = hmac.new(
            self.cohort_secret,
            ROLLOUT_DOMAIN + installation_id.encode("ascii"),
            hashlib.sha256,
        ).digest()
        bucket = int.from_bytes(digest[:8], "big") % ROLLOUT_BUCKETS
        return bucket < self.basis_points

    def allows_artifact(
        self,
        installation_id: str | None,
        signature_key_id: str | None,
        signature_key_sha256: str | None,
        producer_build_sha256: str | None,
        producer_image_digest: str | None,
        client_trust_capabilities: frozenset[tuple[str, str]],
        client_app_build: str | None,
        client_app_git_sha: str | None,
        client_app_build_sha256: str | None,
    ) -> bool:
        if not self.includes(installation_id):
            return False
        artifact_key = (
            (signature_key_id, signature_key_sha256)
            if signature_key_id and signature_key_sha256
            else None
        )
        if artifact_key is None or artifact_key not in client_trust_capabilities:
            return False
        if (
            client_app_build is None
            or client_app_git_sha is None
            or client_app_build_sha256 is None
        ):
            return False
        if self.mode == MapStreamRolloutMode.ALLOWLIST:
            return True
        return bool(
            artifact_key in self.approved_signing_keys
            and producer_build_sha256 == self.producer_build_sha256
            and producer_image_digest == self.worker_image_digest
            and client_app_build == self.required_ios_build
            and client_app_git_sha == self.required_ios_git_sha
            and client_app_build_sha256 == self.required_ios_build_sha256
        )

    def artifact_identity_requirements(
        self,
        client_app_build: str | None,
        client_app_git_sha: str | None,
        client_app_build_sha256: str | None,
    ) -> dict[str, str | int]:
        if self.mode == MapStreamRolloutMode.ALLOWLIST:
            if (
                client_app_build is None
                or client_app_git_sha is None
                or client_app_build_sha256 is None
            ):
                raise ValueError("allowlisted rollout is missing requester app identity")
            return {
                "requiredIosBuild": client_app_build,
                "requiredIosGitSha": client_app_git_sha,
                "requiredIosBuildSha256": client_app_build_sha256,
            }
        if (
            self.required_firmware_version is None
            or self.required_firmware_build is None
            or self.required_firmware_git_sha is None
            or self.required_ios_build is None
            or self.required_ios_git_sha is None
            or self.required_ios_build_sha256 is None
        ):
            raise ValueError("promoted rollout is missing required client/device identity")
        return {
            "requiredIosBuild": self.required_ios_build,
            "requiredIosGitSha": self.required_ios_git_sha,
            "requiredIosBuildSha256": self.required_ios_build_sha256,
            "requiredFirmwareVersion": self.required_firmware_version,
            "requiredFirmwareBuild": self.required_firmware_build,
            "requiredFirmwareGitSha": self.required_firmware_git_sha,
        }

    def public_summary(self) -> dict[str, int | str]:
        summary: dict[str, int | str] = {"mode": self.mode.value}
        if self.mode == MapStreamRolloutMode.ALLOWLIST:
            summary["allowlistCount"] = len(self.allowlist)
        elif self.mode == MapStreamRolloutMode.PERCENTAGE:
            summary["basisPoints"] = self.basis_points
        if self.promotion_id:
            summary["promotionId"] = self.promotion_id
            summary["candidateGitSha"] = self.candidate_git_sha or ""
            summary["producerBuildSha256"] = self.producer_build_sha256 or ""
            summary["workerImageDigest"] = self.worker_image_digest or ""
            summary["requiredFirmwareVersion"] = self.required_firmware_version or ""
            summary["requiredFirmwareBuild"] = self.required_firmware_build or 0
            summary["requiredFirmwareGitSha"] = self.required_firmware_git_sha or ""
            summary["requiredIosBuild"] = self.required_ios_build or ""
            summary["requiredIosGitSha"] = self.required_ios_git_sha or ""
            summary["requiredIosBuildSha256"] = self.required_ios_build_sha256 or ""
            summary["reportSha256"] = self.report_sha256 or ""
            summary["requirementsSha256"] = self.requirements_sha256 or ""
            summary["approvedSigningKeyCount"] = len(
                self.approved_signing_keys
            )
        return summary


def load_approved_promotions(path: Path) -> dict[str, MapStreamPromotionApproval]:
    document = load_strict_json(
        path,
        description="map stream rollout approvals",
    )
    if not isinstance(document, dict) or set(document) != {"schemaVersion", "approvals"}:
        raise ValueError("map stream rollout approvals have unexpected fields")
    if (
        type(document["schemaVersion"]) is not int
        or document["schemaVersion"] != 1
        or not isinstance(document["approvals"], list)
    ):
        raise ValueError("map stream rollout approvals use an unsupported schema")
    promotions: dict[str, MapStreamPromotionApproval] = {}
    for index, approval in enumerate(document["approvals"]):
        if not isinstance(approval, dict) or set(approval) != {
            "promotionId",
            "candidateGitSha",
            "producerBuildSha256",
            "workerImageDigest",
            "firmwareVersion",
            "firmwareBuild",
            "firmwareGitSha",
            "iosBuild",
            "iosGitSha",
            "iosBuildSha256",
            "reportSha256",
            "requirementsSha256",
            "approvedAt",
            "approvedBy",
            "targets",
            "signingKeys",
        }:
            raise ValueError(f"map stream rollout approval {index} has invalid fields")
        promotion_id = approval["promotionId"]
        if not isinstance(promotion_id, str) or not PROMOTION_ID_PATTERN.fullmatch(
            promotion_id
        ):
            raise ValueError(f"map stream rollout approval {index} has an invalid ID")
        if not isinstance(approval["candidateGitSha"], str) or not GIT_SHA_PATTERN.fullmatch(
            approval["candidateGitSha"]
        ):
            raise ValueError(f"map stream rollout approval {index} has an invalid git SHA")
        if (
            not isinstance(approval["producerBuildSha256"], str)
            or not SHA256_PATTERN.fullmatch(approval["producerBuildSha256"])
        ):
            raise ValueError(
                f"map stream rollout approval {index} has an invalid producer build identity"
            )
        if (
            not isinstance(approval["workerImageDigest"], str)
            or not OCI_DIGEST_PATTERN.fullmatch(approval["workerImageDigest"])
        ):
            raise ValueError(
                f"map stream rollout approval {index} has an invalid worker image digest"
            )
        if (
            not isinstance(approval["firmwareVersion"], str)
            or not approval["firmwareVersion"].strip()
        ):
            raise ValueError(
                f"map stream rollout approval {index} has an invalid firmwareVersion"
            )
        if (
            type(approval["firmwareBuild"]) is not int
            or not 1 <= approval["firmwareBuild"] <= UINT32_MAX
            or not isinstance(approval["firmwareGitSha"], str)
            or not GIT_SHA_PATTERN.fullmatch(approval["firmwareGitSha"])
        ):
            raise ValueError(
                f"map stream rollout approval {index} has an invalid firmware build identity"
            )
        if (
            not isinstance(approval["iosBuild"], str)
            or not IOS_BUILD_PATTERN.fullmatch(approval["iosBuild"])
            or not isinstance(approval["iosGitSha"], str)
            or not GIT_SHA_PATTERN.fullmatch(approval["iosGitSha"])
            or not isinstance(approval["iosBuildSha256"], str)
            or not SHA256_PATTERN.fullmatch(approval["iosBuildSha256"])
        ):
            raise ValueError(
                f"map stream rollout approval {index} has an invalid iosBuild"
            )
        for field in ("reportSha256", "requirementsSha256"):
            if not isinstance(approval[field], str) or not SHA256_PATTERN.fullmatch(
                approval[field]
            ):
                raise ValueError(
                    f"map stream rollout approval {index} has an invalid {field}"
                )
        approved_at = approval["approvedAt"]
        if (
            not isinstance(approved_at, str)
            or not TIMESTAMP_PATTERN.fullmatch(approved_at)
        ):
            raise ValueError(f"map stream rollout approval {index} has an invalid approvedAt")
        try:
            parsed_approval_time = datetime.fromisoformat(
                approved_at.removesuffix("Z") + "+00:00"
            )
        except ValueError as exc:
            raise ValueError(
                f"map stream rollout approval {index} has an invalid approvedAt"
            ) from exc
        if parsed_approval_time.tzinfo is None:
            raise ValueError(f"map stream rollout approval {index} has an invalid approvedAt")
        if (
            not isinstance(approval["approvedBy"], str)
            or not approval["approvedBy"].strip()
        ):
            raise ValueError(f"map stream rollout approval {index} has an invalid approvedBy")
        targets = approval["targets"]
        signing_keys = approval["signingKeys"]
        if not isinstance(targets, list) or targets != [
            "WAVESHARE_AMOLED_175",
            "WAVESHARE_AMOLED_206",
        ]:
            raise ValueError(f"map stream rollout approval {index} is missing a target")
        if not isinstance(signing_keys, list) or not signing_keys:
            raise ValueError(
                f"map stream rollout approval {index} has invalid signing keys"
            )
        for value in signing_keys:
            if (
                not isinstance(value, dict)
                or set(value) != {"keyId", "publicKeySha256"}
                or not isinstance(value["keyId"], str)
                or not KEY_ID_PATTERN.fullmatch(value["keyId"])
                or value["keyId"] in FORBIDDEN_FIXTURE_KEY_IDS
                or not isinstance(value["publicKeySha256"], str)
                or not SHA256_PATTERN.fullmatch(value["publicKeySha256"])
            ):
                raise ValueError(
                    f"map stream rollout approval {index} has invalid signing keys"
                )
        signing_key_ids = [value["keyId"] for value in signing_keys]
        if (
            signing_key_ids != sorted(signing_key_ids)
            or len(signing_key_ids) != len(set(signing_key_ids))
        ):
            raise ValueError(
                f"map stream rollout approval {index} has invalid signing keys"
            )
        if promotion_id in promotions:
            raise ValueError("map stream rollout approvals must be unique")
        promotions[promotion_id] = MapStreamPromotionApproval(
            promotion_id=promotion_id,
            candidate_git_sha=approval["candidateGitSha"],
            producer_build_sha256=approval["producerBuildSha256"],
            worker_image_digest=approval["workerImageDigest"],
            firmware_version=approval["firmwareVersion"],
            firmware_build=approval["firmwareBuild"],
            firmware_git_sha=approval["firmwareGitSha"],
            ios_build=approval["iosBuild"],
            ios_git_sha=approval["iosGitSha"],
            ios_build_sha256=approval["iosBuildSha256"],
            report_sha256=approval["reportSha256"],
            requirements_sha256=approval["requirementsSha256"],
            approved_signing_keys=frozenset(
                (value["keyId"], value["publicKeySha256"])
                for value in signing_keys
            ),
        )
    if list(promotions) != sorted(promotions):
        raise ValueError("map stream rollout approvals must be unique and sorted")
    return promotions


def load_approved_promotion_ids(path: Path) -> frozenset[str]:
    return frozenset(load_approved_promotions(path))
