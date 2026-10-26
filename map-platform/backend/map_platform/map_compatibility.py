"""Durable map compatibility contract v1.

``map-platform/config/map-compatibility-contract-v1.json`` is the single
source of truth for maps that must stay usable across app, firmware and
backend releases. A map belongs to the contract exactly when its signed
manifest carries the contract marker; the marker is stamped only for a
registered reader profile and signed only by a registered contract signer.
Delivery metadata (approval, firmware or app identities) never decides
whether such a map is usable.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .strict_json import load_strict_json


CONTRACT_PATH = (
    Path(__file__).resolve().parents[2]
    / "config"
    / "map-compatibility-contract-v1.json"
)
CHANNELS = ("development", "production")
MANIFEST_FIELD = "compatibility"
_IDENTIFIER = re.compile(r"[a-z0-9._-]{1,64}")
_KEY_ID = re.compile(r"[A-Za-z0-9._-]{1,64}")
_SHA256 = re.compile(r"[0-9a-f]{64}")
_BASELINE_ID = re.compile(r"MAP-COMPAT-[0-9]{8}")


class MapCompatibilityError(ValueError):
    pass


@dataclass(frozen=True)
class MapCompatibilityProfile:
    profile_id: str
    renderer: str
    renderer_format_version: int
    features: tuple[str, ...]
    channels: frozenset[str]
    companions: tuple[str, ...]


@dataclass(frozen=True)
class MapCompatibilityContract:
    contract: int
    baseline_id: str
    stream_formats: Mapping[str, frozenset[int]]
    profiles: tuple[MapCompatibilityProfile, ...]
    companions: Mapping[str, tuple[int, int]]
    signers: frozenset[tuple[str, str, str]]
    revoked_signers: frozenset[tuple[str, str]]

    @property
    def manifest_marker(self) -> dict[str, int]:
        return {"contract": self.contract}

    def profile_for(
        self,
        renderer: str,
        renderer_format_version: int,
        features: tuple[str, ...] | list[str],
    ) -> MapCompatibilityProfile | None:
        wanted = tuple(sorted(features))
        for profile in self.profiles:
            if (
                profile.renderer == renderer
                and profile.renderer_format_version == renderer_format_version
                and profile.features == wanted
            ):
                return profile
        return None

    def require_publishable(
        self,
        profile: MapCompatibilityProfile,
        channel: str,
    ) -> None:
        if channel not in profile.channels:
            raise MapCompatibilityError(
                f"durable map profile {profile.profile_id} is not published "
                f"to the {channel} channel"
            )

    def require_signer(
        self,
        channel: str,
        key_id: str,
        public_key_sha256: str,
    ) -> None:
        """Only registered keys may sign maps that readers must keep trusting."""
        if (channel, key_id, public_key_sha256) not in self.signers:
            raise MapCompatibilityError(
                f"signing key {key_id} is not a registered {channel} "
                "durable map signer"
            )


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise MapCompatibilityError(f"map compatibility contract {message}")


def _sorted_unique_strings(value: Any, pattern: re.Pattern[str]) -> bool:
    return (
        isinstance(value, list)
        and all(isinstance(item, str) and pattern.fullmatch(item) for item in value)
        and value == sorted(set(value))
    )


def _positive(value: Any) -> bool:
    return type(value) is int and 1 <= value <= 255


def parse_map_compatibility_contract(document: object) -> MapCompatibilityContract:
    _require(isinstance(document, dict), "must be an object")
    assert isinstance(document, dict)
    _require(
        set(document) == {
            "schemaVersion", "contract", "baselineId", "manifestMarker",
            "streamFormats", "profiles", "companions", "signers",
            "revokedSigners",
        },
        "has unexpected fields",
    )
    _require(document["schemaVersion"] == 1, "schema is unsupported")
    contract = document["contract"]
    _require(_positive(contract), "version is invalid")
    _require(
        isinstance(document["baselineId"], str)
        and _BASELINE_ID.fullmatch(document["baselineId"]) is not None,
        "baseline ID is invalid",
    )
    _require(
        document["manifestMarker"] == {MANIFEST_FIELD: {"contract": contract}},
        "manifest marker does not name its contract",
    )

    stream_formats: dict[str, frozenset[int]] = {}
    for value in document["streamFormats"]:
        _require(
            isinstance(value, dict)
            and set(value) == {"format", "manifestSchemaVersions"}
            and isinstance(value["format"], str)
            and _IDENTIFIER.fullmatch(value["format"]) is not None
            and value["format"] not in stream_formats
            and isinstance(value["manifestSchemaVersions"], list)
            and value["manifestSchemaVersions"]
            and all(_positive(item) for item in value["manifestSchemaVersions"])
            and value["manifestSchemaVersions"]
            == sorted(set(value["manifestSchemaVersions"])),
            "stream format is invalid",
        )
        stream_formats[value["format"]] = frozenset(value["manifestSchemaVersions"])
    _require(bool(stream_formats), "has no stream format")

    companions: dict[str, tuple[int, int]] = {}
    for value in document["companions"]:
        _require(
            isinstance(value, dict)
            and set(value) == {"format", "schemaVersion", "profileVersion"}
            and isinstance(value["format"], str)
            and _IDENTIFIER.fullmatch(value["format"]) is not None
            and value["format"] not in companions
            and _positive(value["schemaVersion"])
            and _positive(value["profileVersion"]),
            "companion is invalid",
        )
        companions[value["format"]] = (
            value["schemaVersion"],
            value["profileVersion"],
        )

    profiles: list[MapCompatibilityProfile] = []
    for value in document["profiles"]:
        _require(
            isinstance(value, dict)
            and set(value) == {
                "id", "renderer", "rendererFormatVersion", "features",
                "channels", "companions",
            }
            and isinstance(value["id"], str)
            and _IDENTIFIER.fullmatch(value["id"]) is not None
            and isinstance(value["renderer"], str)
            and _IDENTIFIER.fullmatch(value["renderer"]) is not None
            and _positive(value["rendererFormatVersion"])
            and _sorted_unique_strings(value["features"], _IDENTIFIER)
            and _sorted_unique_strings(value["channels"], _IDENTIFIER)
            and set(value["channels"]) <= set(CHANNELS)
            and value["channels"]
            and _sorted_unique_strings(value["companions"], _IDENTIFIER)
            and set(value["companions"]) <= set(companions),
            "profile is invalid",
        )
        # The signed contours layer alone requires the iPhone companion.
        _require(
            ("contours" in value["features"])
            == ("topography-ios-v1" in value["companions"]),
            f"profile {value['id']} companion does not follow its contours layer",
        )
        profiles.append(
            MapCompatibilityProfile(
                profile_id=value["id"],
                renderer=value["renderer"],
                renderer_format_version=value["rendererFormatVersion"],
                features=tuple(value["features"]),
                channels=frozenset(value["channels"]),
                companions=tuple(value["companions"]),
            )
        )
    _require(bool(profiles), "has no profile")
    _require(
        len({profile.profile_id for profile in profiles}) == len(profiles),
        "profile IDs are duplicated",
    )
    _require(
        len({
            (profile.renderer, profile.renderer_format_version, profile.features)
            for profile in profiles
        }) == len(profiles),
        "profiles are duplicated",
    )

    def signer_entries(values: object, *, revoked: bool) -> list[tuple[str, ...]]:
        _require(isinstance(values, list), "signers are invalid")
        assert isinstance(values, list)
        entries: list[tuple[str, ...]] = []
        for value in values:
            fields = {"keyId", "publicKeySha256"} | (
                {"reason"} if revoked else {"channel"}
            )
            _require(
                isinstance(value, dict)
                and set(value) == fields
                and isinstance(value["keyId"], str)
                and _KEY_ID.fullmatch(value["keyId"]) is not None
                and isinstance(value["publicKeySha256"], str)
                and _SHA256.fullmatch(value["publicKeySha256"]) is not None,
                "signer is invalid",
            )
            if revoked:
                _require(
                    value["reason"] == "compromised",
                    "signers may be revoked only after a compromise",
                )
                entries.append((value["keyId"], value["publicKeySha256"]))
            else:
                _require(value["channel"] in CHANNELS, "signer channel is invalid")
                entries.append(
                    (value["channel"], value["keyId"], value["publicKeySha256"])
                )
        return entries

    signers = signer_entries(document["signers"], revoked=False)
    revoked = signer_entries(document["revokedSigners"], revoked=True)
    _require(len(set(signers)) == len(signers), "signers are duplicated")
    _require(
        len({entry[1] for entry in signers}) == len(signers),
        "signer key IDs are duplicated",
    )
    _require(
        not {entry[1:] for entry in signers} & set(revoked),
        "a revoked signer is still registered",
    )
    return MapCompatibilityContract(
        contract=contract,
        baseline_id=document["baselineId"],
        stream_formats=stream_formats,
        profiles=tuple(profiles),
        companions=companions,
        signers=frozenset(signers),
        revoked_signers=frozenset(revoked),
    )


def load_map_compatibility_contract(
    path: Path = CONTRACT_PATH,
) -> MapCompatibilityContract:
    return parse_map_compatibility_contract(
        load_strict_json(path, description="map compatibility contract")
    )


def request_profile(
    request: dict[str, Any],
    contract: MapCompatibilityContract,
) -> MapCompatibilityProfile | None:
    """Return the durable profile a renderer request produces, if any.

    Experimental terrain layers and renderer targets outside the contract stay
    uncovered: their manifests carry no marker.
    """
    from .map_labels import renderer_format_version
    from .map_pois import POI_RENDERER_FORMAT_VERSION, requested_poi_features

    target = request.get("target")
    if not isinstance(target, dict) or target.get("terrainProfileVersion") is not None:
        return None
    format_version = renderer_format_version(request)
    features_by_format = {
        1: (),
        2: ("street-labels",),
        3: ("3d-buildings", "street-labels"),
        4: ("3d-buildings", "contours", "street-labels"),
    }
    if format_version == POI_RENDERER_FORMAT_VERSION:
        features = requested_poi_features(request)
    elif format_version in features_by_format:
        features = features_by_format[format_version]
    else:
        return None
    return contract.profile_for("esp32-fmb", format_version, features)


def manifest_contract(manifest: Mapping[str, Any]) -> int | None:
    """Return the contract a canonical map manifest declares, or None."""
    if MANIFEST_FIELD not in manifest:
        return None
    marker = manifest[MANIFEST_FIELD]
    if (
        not isinstance(marker, dict)
        or set(marker) != {"contract"}
        or not _positive(marker["contract"])
    ):
        raise MapCompatibilityError("map manifest compatibility marker is invalid")
    return marker["contract"]


def require_contract_signer(
    manifest: Mapping[str, Any],
    channel: str,
    key_id: str,
    public_key_sha256: str,
    contract: MapCompatibilityContract,
) -> int | None:
    """Fail closed before a durable manifest is signed by an unregistered key."""
    declared = manifest_contract(manifest)
    if declared is None:
        return None
    if declared != contract.contract:
        raise MapCompatibilityError(
            f"map manifest declares unknown compatibility contract {declared}"
        )
    contract.require_signer(channel, key_id, public_key_sha256)
    return declared
