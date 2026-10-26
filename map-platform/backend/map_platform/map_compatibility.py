"""Durable map compatibility contract v1.

``map-platform/config/map-compatibility-contract-v1.json`` is the single
source of truth for maps that must stay usable across app, firmware and
backend releases. A map belongs to the contract exactly when its signed
manifest carries the contract marker, which the producer stamps only for a
registered profile that its channel may publish. Delivery metadata (approval,
firmware or app identities) never decides whether such a map is usable.

``map-compatibility-signers-v1.json`` records the keys that sign durable maps.
Only CI reads it: shipped readers trust exactly the trust-registry keys, and
CI keeps every registered signer trusted until it is revoked for a compromise.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .strict_json import load_strict_json


CONFIG_ROOT = Path(__file__).resolve().parents[2] / "config"
CONTRACT_PATH = CONFIG_ROOT / "map-compatibility-contract-v1.json"
SIGNERS_PATH = CONFIG_ROOT / "map-compatibility-signers-v1.json"
CHANNELS = ("development", "production")
MANIFEST_FIELD = "compatibility"
TERRAIN_EXPERIMENT_LAYER = "terrain-experiment-v1"
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
    optional_layers: tuple[str, ...]


@dataclass(frozen=True)
class MapCompatibilityContract:
    contract: int
    baseline_id: str
    stream_formats: Mapping[str, frozenset[int]]
    profiles: tuple[MapCompatibilityProfile, ...]
    optional_layers: Mapping[str, frozenset[int]]
    companions: Mapping[str, tuple[int, int]]

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

    @staticmethod
    def publishes(profile: MapCompatibilityProfile, channel: str) -> bool:
        return channel in profile.channels

    def require_publishable(
        self,
        profile: MapCompatibilityProfile,
        channel: str,
    ) -> None:
        if not self.publishes(profile, channel):
            raise MapCompatibilityError(
                f"durable map profile {profile.profile_id} is not published "
                f"to the {channel} channel"
            )


@dataclass(frozen=True)
class MapCompatibilitySigners:
    contract: int
    signers: frozenset[tuple[str, str, str]]
    revoked_signers: frozenset[tuple[str, str]]


def _require(condition: object, message: str) -> None:
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


def _versions(value: Any) -> bool:
    return (
        isinstance(value, list)
        and bool(value)
        and all(_positive(item) for item in value)
        and value == sorted(set(value))
    )


def parse_map_compatibility_contract(document: object) -> MapCompatibilityContract:
    _require(isinstance(document, dict), "must be an object")
    assert isinstance(document, dict)
    _require(
        set(document) == {
            "schemaVersion", "contract", "baselineId", "manifestMarker",
            "streamFormats", "profiles", "optionalLayers", "companions",
        },
        "has unexpected fields",
    )
    _require(document["schemaVersion"] == 1, "schema is unsupported")
    _require(
        all(
            isinstance(document[key], list)
            for key in ("streamFormats", "profiles", "optionalLayers", "companions")
        ),
        "lists are invalid",
    )
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
            and _versions(value["manifestSchemaVersions"]),
            "stream format is invalid",
        )
        stream_formats[value["format"]] = frozenset(value["manifestSchemaVersions"])
    _require(stream_formats, "has no stream format")

    optional_layers: dict[str, frozenset[int]] = {}
    for value in document["optionalLayers"]:
        _require(
            isinstance(value, dict)
            and set(value) == {"id", "rendererFormatVersions"}
            and isinstance(value["id"], str)
            and _IDENTIFIER.fullmatch(value["id"]) is not None
            and value["id"] not in optional_layers
            and _versions(value["rendererFormatVersions"]),
            "optional layer is invalid",
        )
        optional_layers[value["id"]] = frozenset(value["rendererFormatVersions"])

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
                "channels", "companions", "optionalLayers",
            }
            and isinstance(value["id"], str)
            and _IDENTIFIER.fullmatch(value["id"]) is not None
            and isinstance(value["renderer"], str)
            and _IDENTIFIER.fullmatch(value["renderer"]) is not None
            and _positive(value["rendererFormatVersion"])
            and _sorted_unique_strings(value["features"], _IDENTIFIER)
            and _sorted_unique_strings(value["channels"], _IDENTIFIER)
            and value["channels"]
            and set(value["channels"]) <= set(CHANNELS)
            and _sorted_unique_strings(value["companions"], _IDENTIFIER)
            and set(value["companions"]) <= set(companions)
            and _sorted_unique_strings(value["optionalLayers"], _IDENTIFIER)
            and all(
                value["rendererFormatVersion"] in optional_layers.get(layer, ())
                for layer in value["optionalLayers"]
            ),
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
                optional_layers=tuple(value["optionalLayers"]),
            )
        )
    _require(profiles, "has no profile")
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
    return MapCompatibilityContract(
        contract=contract,
        baseline_id=document["baselineId"],
        stream_formats=stream_formats,
        profiles=tuple(profiles),
        optional_layers=optional_layers,
        companions=companions,
    )


def load_map_compatibility_contract(
    path: Path = CONTRACT_PATH,
) -> MapCompatibilityContract:
    return parse_map_compatibility_contract(
        load_strict_json(path, description="map compatibility contract")
    )


def parse_map_compatibility_signers(document: object) -> MapCompatibilitySigners:
    _require(
        isinstance(document, dict)
        and set(document) == {"schemaVersion", "contract", "signers", "revokedSigners"}
        and document["schemaVersion"] == 1
        and _positive(document["contract"])
        and isinstance(document["signers"], list)
        and isinstance(document["revokedSigners"], list),
        "signer registry is invalid",
    )
    assert isinstance(document, dict)
    signers: list[tuple[str, str, str]] = []
    for value in document["signers"]:
        _require(
            isinstance(value, dict)
            and set(value) == {"channel", "keyId", "publicKeySha256"}
            and value["channel"] in CHANNELS
            and isinstance(value["keyId"], str)
            and _KEY_ID.fullmatch(value["keyId"]) is not None
            and isinstance(value["publicKeySha256"], str)
            and _SHA256.fullmatch(value["publicKeySha256"]) is not None,
            "signer is invalid",
        )
        signers.append((value["channel"], value["keyId"], value["publicKeySha256"]))
    revoked: list[tuple[str, str]] = []
    for value in document["revokedSigners"]:
        # A durable signer leaves client trust only after a compromise, which
        # deliberately revokes every map it signed.
        _require(
            isinstance(value, dict)
            and set(value) == {"keyId", "publicKeySha256", "reason"}
            and value["reason"] == "compromised"
            and isinstance(value["keyId"], str)
            and _KEY_ID.fullmatch(value["keyId"]) is not None
            and isinstance(value["publicKeySha256"], str)
            and _SHA256.fullmatch(value["publicKeySha256"]) is not None,
            "revoked signer is invalid",
        )
        revoked.append((value["keyId"], value["publicKeySha256"]))
    _require(len(set(signers)) == len(signers), "signers are duplicated")
    _require(
        len({entry[1] for entry in signers}) == len(signers),
        "signer key IDs are duplicated",
    )
    _require(
        not {entry[1:] for entry in signers} & set(revoked),
        "a revoked signer is still registered",
    )
    return MapCompatibilitySigners(
        contract=document["contract"],
        signers=frozenset(signers),
        revoked_signers=frozenset(revoked),
    )


def load_map_compatibility_signers(
    path: Path = SIGNERS_PATH,
) -> MapCompatibilitySigners:
    return parse_map_compatibility_signers(
        load_strict_json(path, description="map compatibility signers")
    )


def request_profile(
    request: dict[str, Any],
    contract: MapCompatibilityContract,
) -> MapCompatibilityProfile | None:
    """Return the durable profile a renderer request produces, if any.

    Renderer targets outside the contract stay uncovered: their manifests carry
    no marker. A terrain experiment is an optional layer that every reader of
    its profile must accept and may ignore.
    """
    from .map_labels import renderer_format_version
    from .map_pois import POI_RENDERER_FORMAT_VERSION, requested_poi_features

    target = request.get("target")
    if not isinstance(target, dict):
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
    profile = contract.profile_for("esp32-fmb", format_version, features)
    terrain = target.get("terrainProfileVersion")
    if profile is not None and terrain is not None and (
        type(terrain) is not int
        or terrain != 1
        or TERRAIN_EXPERIMENT_LAYER not in profile.optional_layers
    ):
        return None
    return profile


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
