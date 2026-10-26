"""Durable map compatibility contract v1 and its frozen producer corpus.

The corpus under ``fixtures/map-compatibility-v1`` was produced once by the
real packaging, promotion and signing code (``map_compatibility_fixture.py``).
These tests pin its exact bytes, then check that the current backend still
reads every frozen map and gives direct-job and catalog delivery the same
compatibility meaning. Never regenerate a corpus to make a test pass.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from cryptography.hazmat.primitives.asymmetric import ec

from map_platform.artifacts import BIKE_MAP_STREAM_FORMAT, TOPOGRAPHY_COMPANION_FORMAT
from map_platform.catalog import publication_payload
from map_platform.map_compatibility import (
    TERRAIN_EXPERIMENT_LAYER,
    MapCompatibilityError,
    load_map_compatibility_contract,
    load_map_compatibility_signers,
    manifest_contract,
    parse_map_compatibility_contract,
    parse_map_compatibility_signers,
    request_profile,
)
from map_platform.map_stream import (
    FIXED_HEADER_BYTES,
    MapStreamHeader,
    MapStreamSignatureEnvelope,
    manifest_receipt,
    signed_manifest_receipt,
)
from map_platform.map_stream_rollout import MapStreamRolloutMode, MapStreamRolloutPolicy
from map_platform.map_stream_trust_registry import (
    FORBIDDEN_FIXTURE_KEY_IDS,
    FORBIDDEN_FIXTURE_PUBLIC_KEYS,
    load_trust_registry,
)
from map_platform.models import COMPATIBILITY_CONTRACT_METRIC, MapJob
from map_platform.topography_companion import validate_companion


TESTS = Path(__file__).resolve().parent
REPO = TESTS.parents[2]
FIXTURES = TESTS / "fixtures"
EXTRACTION = FIXTURES / "map-compatibility-extraction-v1"
CONFIG = REPO / "map-platform" / "config"
# Pinned once when each corpus was frozen. A changed index means old fixtures
# were rewritten; add a new corpus directory for a later revision instead.
FROZEN_CORPORA = {
    "map-compatibility-v1": (
        "98db28f8e16803b524efa2fe19da0cf4bae17c2d8998dc6b3449aa33481f8065",
        "d18579a71628bba351d5a45011f01f9337a6b178f8f2d73fd00c4f655f02b462",
    ),
}
# Contract v1 as first published. Profiles, channels and optional layers may
# be appended in a reviewed contract change; none of these may be removed.
V1_PROFILES = {
    "buildings-3d-v1": (
        3, ("3d-buildings", "street-labels"), {"development", "production"}, (),
    ),
    "topographic-contours-v1": (
        4, ("3d-buildings", "contours", "street-labels"),
        {"development", "production"}, (TERRAIN_EXPERIMENT_LAYER,),
    ),
    "map-pois-v1": (5, ("3d-buildings", "map-pois", "street-labels"), {"development"}, ()),
    "map-pois-contours-v1": (
        5, ("3d-buildings", "contours", "map-pois", "street-labels"), {"development"}, (),
    ),
}
# Keys that sign durable maps. Each stays registered and client-trusted until
# it is moved to revokedSigners after a compromise.
V1_SIGNERS = {
    ("development", "map-dev-2026-08",
     "c8d0e9e85da681ec048c9abbbb96c87072b9f672b16c7fb40250df1ec60baa0e"),
    ("production", "map-prod-2026-08",
     "8042e4bbac215fcebb44a157849b252a844f195e634f89a9b8fdd989cf681c12"),
}


def corpus_directories() -> list[Path]:
    return sorted(FIXTURES.glob("map-compatibility-v*"))


def load_corpus(directory: Path) -> dict:
    return json.loads((directory / "corpus.json").read_text(encoding="utf-8"))


def all_entries() -> list[tuple[Path, dict, dict]]:
    """Every frozen map as (corpus directory, corpus, entry)."""
    result = []
    for directory in corpus_directories():
        corpus = load_corpus(directory)
        result.extend((directory, corpus, entry) for entry in corpus["maps"])
    return result


def variants(entry: dict) -> list[dict]:
    return [entry["development"], *entry["production"]]


def stream_artifact(variant: dict) -> dict:
    return next(
        value for value in variant["publication"]["artifacts"]
        if value["format"] == BIKE_MAP_STREAM_FORMAT
    )


def stream_parts(data: bytes) -> tuple[MapStreamHeader, bytes, bytes, dict]:
    header = MapStreamHeader.decode(data[:FIXED_HEADER_BYTES])
    manifest_end = FIXED_HEADER_BYTES + header.manifest_bytes
    manifest = data[FIXED_HEADER_BYTES:manifest_end]
    envelope = data[manifest_end:manifest_end + header.signature_envelope_bytes]
    return header, manifest, envelope, json.loads(manifest)


def verify_signature(manifest: bytes, envelope: bytes, public_key_hex: str) -> bool:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

    decoded = MapStreamSignatureEnvelope.decode(envelope)
    public_key = ec.EllipticCurvePublicKey.from_encoded_point(
        ec.SECP256R1(), bytes.fromhex(public_key_hex)
    )
    r = int.from_bytes(decoded.raw_signature[:32], "big")
    s = int.from_bytes(decoded.raw_signature[32:], "big")
    try:
        public_key.verify(
            encode_dss_signature(r, s),
            b"open-bike-computer-map-manifest-v1\0" + manifest,
            ec.ECDSA(hashes.SHA256()),
        )
    except InvalidSignature:
        return False
    return True


class MapCompatibilityContractFileTests(unittest.TestCase):
    def test_contract_v1_is_valid_and_append_only(self):
        contract = load_map_compatibility_contract()
        self.assertEqual(contract.contract, 1)
        self.assertEqual(contract.baseline_id, "MAP-COMPAT-20261026")
        self.assertEqual(
            dict(contract.stream_formats), {"bike-map-stream-v1": frozenset({1})}
        )
        profiles = {profile.profile_id: profile for profile in contract.profiles}
        for profile_id, (format_version, features, channels, layers) in V1_PROFILES.items():
            with self.subTest(profile=profile_id):
                profile = profiles[profile_id]
                self.assertEqual(profile.renderer, "esp32-fmb")
                self.assertEqual(profile.renderer_format_version, format_version)
                self.assertEqual(profile.features, features)
                self.assertTrue(channels <= profile.channels)
                self.assertTrue(set(layers) <= set(profile.optional_layers))

    def test_parser_rejects_ambiguous_or_weakened_contracts(self):
        document = json.loads(
            (CONFIG / "map-compatibility-contract-v1.json").read_text(encoding="utf-8")
        )
        changes = {
            "unknown field": lambda value: value.update(extra=True),
            "marker mismatch": lambda value: value.update(
                manifestMarker={"compatibility": {"contract": 2}}
            ),
            "duplicate profile": lambda value: value["profiles"].append(
                dict(value["profiles"][0], id="copy")
            ),
            "unknown channel": lambda value: value["profiles"][0].update(
                channels=["development", "staging"]
            ),
            "contours without companion": lambda value: value["profiles"][1].update(
                companions=[]
            ),
            "unknown optional layer": lambda value: value["profiles"][0].update(
                optionalLayers=["shaded-relief"]
            ),
            "layer on another target": lambda value: value["profiles"][0].update(
                optionalLayers=[TERRAIN_EXPERIMENT_LAYER]
            ),
        }
        for name, change in changes.items():
            with self.subTest(change=name):
                candidate = json.loads(json.dumps(document))
                change(candidate)
                with self.assertRaises(MapCompatibilityError):
                    parse_map_compatibility_contract(candidate)

    def test_durable_signers_stay_registered_and_client_trusted(self):
        registry = load_map_compatibility_signers()
        self.assertEqual(registry.contract, 1)
        revoked = registry.revoked_signers
        for signer in V1_SIGNERS:
            with self.subTest(signer=signer[1]):
                # Removing a durable signer strands every map it signed. Only a
                # compromise revocation may take it out of the registry.
                self.assertTrue(signer in registry.signers or signer[1:] in revoked)
        trusted = {
            (key.key_id, hashlib.sha256(bytes.fromhex(key.public_key_x963_hex)).hexdigest())
            for key in load_trust_registry(CONFIG / "map-stream-trust.json")
            if key.state == "trusted"
        }
        settings = dict(
            line.split(" = ", 1)
            for line in (
                REPO / "ios-app" / "BikeComputer" / "Configuration" / "Development.xcconfig"
            ).read_text(encoding="utf-8").splitlines()
            if " = " in line
        )
        # Bicino Dev and development firmware trust exactly one development
        # key, so it cannot be replaced until both readers accept several.
        development = (
            settings["BICINO_MAP_DEVELOPMENT_SIGNING_KEY_ID"].strip(),
            hashlib.sha256(bytes.fromhex(
                settings["BICINO_MAP_DEVELOPMENT_SIGNING_PUBLIC_KEY_X963_HEX"].strip()
            )).hexdigest(),
        )
        firmware = re.findall(
            r'"([^"]+)"',
            (
                REPO / "esp32" / "lib" / "map_transfer"
                / "map_stream_development_compiled_key.generated.inc"
            ).read_text(encoding="utf-8").split("{", 1)[1],
        )
        self.assertEqual((firmware[0], firmware[2]), development)
        for channel, key_id, key_sha256 in registry.signers:
            with self.subTest(registered=key_id):
                if channel == "production":
                    self.assertIn((key_id, key_sha256), trusted)
                else:
                    self.assertEqual((key_id, key_sha256), development)
        self.assertFalse(revoked & trusted)
        self.assertNotIn(development, revoked)

    def test_signer_registry_parser_is_strict(self):
        document = json.loads(
            (CONFIG / "map-compatibility-signers-v1.json").read_text(encoding="utf-8")
        )
        changes = {
            "unknown field": lambda value: value.update(extra=True),
            "retirement without compromise": lambda value: value.update(
                revokedSigners=[{
                    "keyId": "map-prod-2026-07", "publicKeySha256": "a" * 64,
                    "reason": "rotated",
                }]
            ),
            "revoked but still registered": lambda value: value.update(
                revokedSigners=[{
                    "keyId": value["signers"][1]["keyId"],
                    "publicKeySha256": value["signers"][1]["publicKeySha256"],
                    "reason": "compromised",
                }]
            ),
            "unknown channel": lambda value: value["signers"][0].update(channel="lab"),
            "duplicate key ID": lambda value: value["signers"].append(
                dict(value["signers"][0], channel="production")
            ),
        }
        for name, change in changes.items():
            with self.subTest(change=name):
                candidate = json.loads(json.dumps(document))
                change(candidate)
                with self.assertRaises(MapCompatibilityError):
                    parse_map_compatibility_signers(candidate)

    def test_generation_policies_never_publish_an_unregistered_durable_channel(self):
        contract = load_map_compatibility_contract()
        for path in sorted(CONFIG.glob("generation-profile-policy-v*.json")):
            policy = json.loads(path.read_text(encoding="utf-8"))
            profiles = {value["id"]: value for value in policy["profiles"]}
            for channel, settings in policy["channels"].items():
                for profile_id in settings["globalProfiles"] + settings["canaryProfiles"]:
                    profile = profiles[profile_id]
                    feature_sets = [tuple(sorted(profile["features"]))]
                    feature_sets += [
                        tuple(sorted(profile["features"] + [feature]))
                        for feature in profile.get("optionalFeatures", [])
                        if feature in settings.get("globalOptionalFeatures", [])
                        + settings.get("canaryOptionalFeatures", [])
                    ]
                    for features in feature_sets:
                        durable = contract.profile_for(
                            "esp32-fmb", profile["rendererFormatVersion"], features
                        )
                        with self.subTest(policy=path.name, channel=channel, features=features):
                            if durable is not None:
                                self.assertIn(channel, durable.channels)

    def test_marked_profiles_include_optional_terrain_but_never_unknown_targets(self):
        contract = load_map_compatibility_contract()

        def request(format_version, **target):
            return {"target": {
                "renderer": "esp32-fmb", "rendererFormatVersion": format_version, **target,
            }}

        self.assertIsNone(request_profile(request(1), contract))
        self.assertIsNone(request_profile(request(2), contract))
        self.assertEqual(request_profile(request(3), contract).profile_id, "buildings-3d-v1")
        # The terrain experiment is an optional layer, so the connected bike's
        # diagnostics support never decides whether a contour map is durable.
        for target in ({}, {"terrainProfileVersion": 1}):
            with self.subTest(target=target):
                self.assertEqual(
                    request_profile(request(4, **target), contract).profile_id,
                    "topographic-contours-v1",
                )
        self.assertEqual(
            request_profile(request(5, requestedFeatures=[
                "3d-buildings", "map-pois", "street-labels",
            ]), contract).profile_id,
            "map-pois-v1",
        )
        self.assertIsNone(request_profile(request(9), contract))
        self.assertIsNone(request_profile({"target": None}, contract))
        poi = contract.profile_for("esp32-fmb", 5, ("3d-buildings", "map-pois", "street-labels"))
        self.assertTrue(contract.publishes(poi, "development"))
        # The producer leaves it unmarked instead; CI keeps policies in sync.
        self.assertFalse(contract.publishes(poi, "production"))
        with self.assertRaisesRegex(MapCompatibilityError, "not published to the production"):
            contract.require_publishable(poi, "production")

    def test_manifest_marker_is_strict(self):
        self.assertEqual(manifest_contract({"compatibility": {"contract": 1}}), 1)
        self.assertIsNone(manifest_contract({}))
        for marker in ({"contract": 0}, {"contract": "1"}, {"contract": 1, "extra": 1},
                       {"contract": 256}, [1]):
            with self.subTest(marker=marker), self.assertRaises(MapCompatibilityError):
                manifest_contract({"compatibility": marker})

    def test_classification_survives_an_older_control_plane_rewrite(self):
        _directory, _corpus, entry = all_entries()[0]
        document = json.loads(json.dumps(entry["job"]))
        job = MapJob.from_dict(document)
        self.assertEqual(job.compatibility_contract, 1)
        persisted = job.to_dict(include_internal=True)
        # Older models drop unknown top-level fields when they rewrite a job,
        # but keep artifact metrics verbatim. The classification must live
        # there and nowhere else.
        self.assertNotIn("compatibilityContract", persisted)
        self.assertEqual(persisted["artifactMetrics"][COMPATIBILITY_CONTRACT_METRIC], 1)
        rewritten = MapJob.from_dict(json.loads(json.dumps(persisted)))
        self.assertEqual(rewritten.compatibility_contract, 1)
        for metrics in (None, {}, {COMPATIBILITY_CONTRACT_METRIC: 0},
                        {COMPATIBILITY_CONTRACT_METRIC: "1"},
                        {COMPATIBILITY_CONTRACT_METRIC: True}):
            with self.subTest(metrics=metrics):
                self.assertIsNone(
                    MapJob.from_dict({**document, "artifactMetrics": metrics})
                    .compatibility_contract
                )


class FrozenCorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.entries = all_entries()

    def test_corpus_bytes_are_frozen(self):
        directories = {path.name: path for path in corpus_directories()}
        self.assertEqual(set(directories), set(FROZEN_CORPORA))
        for name, (json_sha256, index_sha256) in FROZEN_CORPORA.items():
            directory = directories[name]
            corpus = load_corpus(directory)
            with self.subTest(corpus=name):
                self.assertEqual(
                    hashlib.sha256((directory / "corpus.json").read_bytes()).hexdigest(),
                    json_sha256,
                )
                self.assertEqual(
                    hashlib.sha256((directory / "corpus.txt").read_bytes()).hexdigest(),
                    index_sha256,
                )
                present = {
                    path.name for path in directory.iterdir()
                    if path.name not in {"corpus.json", "corpus.txt", "README.md"}
                }
                self.assertEqual(present, set(corpus["files"]))
                for file_name, sha256 in corpus["files"].items():
                    self.assertEqual(
                        hashlib.sha256((directory / file_name).read_bytes()).hexdigest(),
                        sha256,
                    )

    def test_corpora_cover_every_contract_profile_channel_and_layer(self):
        contract = load_map_compatibility_contract()
        for profile in contract.profiles:
            with self.subTest(profile=profile.profile_id):
                entries = [entry for _, _, entry in self.entries
                           if entry["profile"] == profile.profile_id]
                self.assertTrue(entries)
                for entry in entries:
                    self.assertEqual(entry["rendererFormatVersion"], profile.renderer_format_version)
                    self.assertEqual(tuple(entry["features"]), profile.features)
                    self.assertEqual(entry["companionFile"] is not None, bool(profile.companions))
                    self.assertTrue(set(entry["optionalLayers"]) <= set(profile.optional_layers))
                self.assertEqual(
                    any(entry["production"] for entry in entries),
                    "production" in profile.channels,
                )
                self.assertEqual(
                    {layer for entry in entries for layer in entry["optionalLayers"]},
                    set(profile.optional_layers),
                )
        for _, corpus, _ in self.entries:
            for signer in corpus["signers"]:
                self.assertIn(signer["keyId"], FORBIDDEN_FIXTURE_KEY_IDS)
                self.assertIn(signer["publicKeyX963Hex"], FORBIDDEN_FIXTURE_PUBLIC_KEYS)

    def test_osm_maps_carry_the_frozen_worker_extraction(self):
        extracted = [entry for _, _, entry in self.entries if entry["extraction"]]
        # Real extraction output covers the production 3D target and the POI
        # target; the other maps use test-helper blocks.
        self.assertEqual(
            {entry["rendererFormatVersion"] for entry in extracted}, {3, 5}
        )
        for directory, _, entry in self.entries:
            if not entry["extraction"]:
                continue
            source = EXTRACTION / entry["extraction"]
            expected = {
                f"VECTMAP/{entry['mapId']}/{path.relative_to(source).as_posix()}":
                    hashlib.sha256(path.read_bytes()).hexdigest()
                for path in source.rglob("*") if path.is_file()
            }
            for variant in variants(entry):
                with self.subTest(file=variant["file"]):
                    _header, _manifest, _envelope, parsed = stream_parts(
                        (directory / variant["file"]).read_bytes()
                    )
                    files = {file["path"]: file["sha256"] for file in parsed["files"]}
                    self.assertEqual(
                        {path: files.get(path) for path in expected}, expected
                    )

    def test_every_frozen_stream_still_verifies_and_declares_its_profile(self):
        contract = load_map_compatibility_contract()
        for directory, corpus, entry in self.entries:
            signers = {value["keyId"]: value for value in corpus["signers"]}
            for variant in variants(entry):
                with self.subTest(file=variant["file"]):
                    data = (directory / variant["file"]).read_bytes()
                    header, manifest, envelope, parsed = stream_parts(data)
                    stream = stream_artifact(variant)
                    signer = signers[stream["signatureKeyId"]]
                    self.assertEqual(signer["channel"], variant["deliveryTier"])
                    self.assertTrue(verify_signature(manifest, envelope, signer["publicKeyX963Hex"]))
                    self.assertEqual(stream["sha256"], hashlib.sha256(data).hexdigest())
                    self.assertEqual(stream["bytes"], len(data))
                    self.assertEqual(stream["manifestReceipt"], manifest_receipt(manifest))
                    self.assertEqual(
                        stream["signedManifestReceipt"],
                        signed_manifest_receipt(manifest, envelope),
                    )
                    self.assertEqual(manifest_contract(parsed), contract.contract)
                    profile = contract.profile_for(
                        parsed["target"]["renderer"], parsed["target"]["formatVersion"],
                        entry["features"],
                    )
                    self.assertEqual(profile.profile_id, entry["profile"])
                    has_terrain = any(file["path"].endswith(".fme") for file in parsed["files"])
                    self.assertEqual(has_terrain, TERRAIN_EXPERIMENT_LAYER in entry["optionalLayers"])
                    self.assertEqual(
                        stream["readerRequirements"],
                        {
                            "schemaVersion": 1, "streamFormat": BIKE_MAP_STREAM_FORMAT,
                            "manifestSchemaVersion": parsed["schemaVersion"],
                            "renderer": parsed["target"]["renderer"],
                            "rendererFormatVersion": parsed["target"]["formatVersion"],
                            "requiredFeatures": entry["features"],
                        },
                    )
                    # A durable map is never bound to a firmware build.
                    for field in ("requiredFirmwareVersion", "requiredFirmwareBuild",
                                  "requiredFirmwareGitSha"):
                        self.assertNotIn(field, stream)
                    payload = data[
                        FIXED_HEADER_BYTES + header.manifest_bytes
                        + header.signature_envelope_bytes:
                    ]
                    offset = 0
                    for file in parsed["files"]:
                        body = payload[offset:offset + file["bytes"]]
                        self.assertEqual(hashlib.sha256(body).hexdigest(), file["sha256"])
                        offset += file["bytes"]
                    self.assertEqual(offset, len(payload))

    def test_corrupt_and_untrusted_streams_are_rejected(self):
        directory, corpus, entry = self.entries[0]
        signers = {value["keyId"]: value for value in corpus["signers"]}
        data = (directory / entry["development"]["file"]).read_bytes()
        header, manifest, envelope, _parsed = stream_parts(data)
        development_key = signers[stream_artifact(entry["development"])["signatureKeyId"]]
        production_key = next(
            value for value in corpus["signers"] if value["channel"] == "production"
        )
        self.assertFalse(verify_signature(manifest, envelope, production_key["publicKeyX963Hex"]))
        tampered = bytearray(manifest)
        tampered[-2] ^= 1
        self.assertFalse(
            verify_signature(bytes(tampered), envelope, development_key["publicKeyX963Hex"])
        )
        payload_start = FIXED_HEADER_BYTES + header.manifest_bytes + header.signature_envelope_bytes
        corrupted = bytearray(data)
        corrupted[payload_start] ^= 1
        _, _, _, parsed = stream_parts(bytes(corrupted))
        first = parsed["files"][0]
        self.assertNotEqual(
            hashlib.sha256(bytes(corrupted[payload_start:payload_start + first["bytes"]])).hexdigest(),
            first["sha256"],
        )
        with self.assertRaises(ValueError):
            MapStreamHeader.decode(data[:FIXED_HEADER_BYTES - 1])

    @unittest.skipUnless(importlib.util.find_spec("rasterio"), "topography native dependencies required")
    def test_frozen_companions_match_their_signed_contours(self):
        for directory, corpus, entry in self.entries:
            if entry["companionFile"] is None:
                continue
            with self.subTest(map=entry["id"]):
                _header, _manifest, _envelope, parsed = stream_parts(
                    (directory / entry["development"]["file"]).read_bytes()
                )
                with tempfile.TemporaryDirectory() as temporary:
                    path = Path(temporary) / f"{entry['mapId']}.btopo"
                    path.write_bytes((directory / entry["companionFile"]).read_bytes())
                    metadata = validate_companion(
                        path, expected_map_id=entry["mapId"],
                        expected_intermediate=parsed["topography"]["intermediateSha256"],
                    )
                self.assertEqual(
                    metadata["attributionSha256"], parsed["topography"]["attributionSha256"]
                )
                companions = [
                    value
                    for variant in variants(entry)
                    for value in variant["publication"]["artifacts"]
                    if value["format"] == TOPOGRAPHY_COMPANION_FORMAT
                ]
                self.assertEqual(len(companions), len(variants(entry)))
                self.assertEqual({value["sha256"] for value in companions},
                                 {corpus["files"][entry["companionFile"]]})

    def test_promotion_rotation_and_worker_update_keep_one_catalog_map(self):
        entry = next(entry for _, _, entry in self.entries
                     if len(entry["production"]) == 3)
        publications = [variant["publication"] for variant in variants(entry)]
        self.assertEqual({value["mapEntryId"] for value in publications}, {entry["mapEntryId"]})
        self.assertEqual({value["contentReceipt"] for value in publications}, {entry["contentReceipt"]})
        streams = {
            variant["variant"]: stream_artifact(variant) for variant in entry["production"]
        }
        # Key rotation keeps the signed content; a worker update re-signs the
        # same map content under its own producer identity.
        self.assertEqual(
            streams["production"]["manifestReceipt"],
            streams["production-rotated-key"]["manifestReceipt"],
        )
        self.assertNotEqual(
            streams["production"]["signatureKeyId"],
            streams["production-rotated-key"]["signatureKeyId"],
        )
        self.assertNotEqual(
            streams["production"]["producerBuildSha256"],
            streams["production-updated-worker"]["producerBuildSha256"],
        )


class DeliveryParityTests(unittest.TestCase):
    """Direct jobs and the catalog give a durable map the same meaning."""

    FIRMWARE_GATE = {
        "MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_VERSION": "0.3.4",
        "MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_BUILD": "104",
        "MAP_PLATFORM_CATALOG_REQUIRED_FIRMWARE_GIT_SHA": "4" * 40,
    }

    @classmethod
    def setUpClass(cls):
        cls.entries = all_entries()

    def test_current_publisher_reproduces_frozen_catalog_meaning(self):
        for _, _, entry in self.entries:
            with self.subTest(map=entry["id"]):
                # The persisted READY job, as a backend update or retry
                # republishes it.
                job = MapJob.from_dict(entry["job"])
                self.assertEqual(job.compatibility_contract, entry["compatibilityContract"])
                frozen = entry["development"]["publication"]
                with patch.dict(os.environ, self.FIRMWARE_GATE):
                    current = publication_payload(job, "development")
                self.assertEqual(
                    {value["artifactId"]: value for value in current["artifacts"]},
                    {value["artifactId"]: value for value in frozen["artifacts"]},
                )
                for field in ("mapEntryId", "contentReceipt", "renderer",
                              "rendererFormatVersion", "features"):
                    self.assertEqual(current[field], frozen[field])

    def test_maps_outside_the_contract_keep_their_configured_firmware_gate(self):
        _, _, entry = self.entries[0]
        job = MapJob.from_dict({**entry["job"], "artifactMetrics": None})
        self.assertIsNone(job.compatibility_contract)
        with patch.dict(os.environ, self.FIRMWARE_GATE):
            payload = publication_payload(job, "development")
        self.assertEqual(stream_artifact({"publication": payload})["requiredFirmwareBuild"], 104)

    def test_rollout_keeps_earlier_approved_durable_maps_after_a_worker_update(self):
        entry = next(entry for _, _, entry in self.entries if len(entry["production"]) == 3)
        production = {variant["variant"]: variant for variant in entry["production"]}
        original = stream_artifact(production["production"])
        updated = stream_artifact(production["production-updated-worker"])
        rotated = stream_artifact(production["production-rotated-key"])
        signers = {
            (value["signatureKeyId"], value["signatureKeySha256"])
            for value in (original, rotated)
        }
        policy = MapStreamRolloutPolicy(
            mode=MapStreamRolloutMode.ALL,
            producer_build_sha256=updated["producerBuildSha256"],
            worker_image_digest=updated["producerImageDigest"],
            required_firmware_version="0.3.5",
            required_firmware_build=105,
            required_firmware_git_sha="5" * 40,
            approved_signing_keys=frozenset({
                (updated["signatureKeyId"], updated["signatureKeySha256"])
            }),
            approved_producers=frozenset(
                (value["producerBuildSha256"], value["producerImageDigest"],
                 value["signatureKeyId"], value["signatureKeySha256"])
                for value in (original, updated, rotated)
            ),
        )
        installation = "inst_v2_" + "0" * 31 + "1"

        def allowed(stream, contract, trust=signers, rollout=policy):
            return rollout.allows_artifact(
                installation, stream["signatureKeyId"], stream["signatureKeySha256"],
                stream["producerBuildSha256"], stream["producerImageDigest"],
                frozenset(trust), None, None, None, compatibility_contract=contract,
            )

        for stream in (original, updated, rotated):
            with self.subTest(producer=stream["producerBuildSha256"][:8],
                              key=stream["signatureKeyId"]):
                self.assertTrue(allowed(stream, 1))
        # Maps outside the contract keep the single-approval rule.
        self.assertFalse(allowed(original, None))
        self.assertTrue(allowed(updated, None))
        # A client that no longer trusts the signer never receives the map.
        self.assertFalse(allowed(rotated, 1, trust={
            (original["signatureKeyId"], original["signatureKeySha256"])
        }))
        # Removing the earlier approval is the revocation path.
        revoked = replace(policy, approved_producers=frozenset(
            item for item in policy.approved_producers
            if item[0] != original["producerBuildSha256"]
        ))
        self.assertFalse(allowed(original, 1, rollout=revoked))
        self.assertEqual(policy.artifact_delivery_requirements(compatibility_contract=1), {})
        self.assertEqual(
            policy.artifact_delivery_requirements(compatibility_contract=None)[
                "requiredFirmwareBuild"
            ],
            105,
        )


class PromotionTests(unittest.TestCase):
    """Production promotion keeps a durable map durable and ungated."""

    @classmethod
    def setUpClass(cls):
        from tests import map_compatibility_fixture as fixture

        cls.fixture = fixture
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.contract = load_map_compatibility_contract()
        cls.job, cls.artifact_root = fixture.build_development_map(
            cls.root / "map", "buildings-3d-v1", cls.contract,
        )
        cls.publication = publication_payload(cls.job, "development")

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_promotion_ignores_configured_firmware_gates_for_durable_maps(self):
        with patch.dict(os.environ, DeliveryParityTests.FIRMWARE_GATE):
            _result, publication = self.fixture.promote(
                self.job, self.publication, self.artifact_root,
                self.root / "gated", "production", self.contract,
            )
        stream = stream_artifact({"publication": publication})
        self.assertEqual(publication["contentReceipt"], self.publication["contentReceipt"])
        for field in ("requiredFirmwareVersion", "requiredFirmwareBuild", "requiredFirmwareGitSha"):
            self.assertNotIn(field, stream)

    def test_promotion_refuses_a_profile_production_may_not_publish(self):
        from map_platform.catalog_promotion import CatalogPromotionError

        contract = replace(self.contract, profiles=tuple(
            replace(profile, channels=frozenset({"development"}))
            if profile.profile_id == "buildings-3d-v1" else profile
            for profile in self.contract.profiles
        ))
        with self.assertRaisesRegex(CatalogPromotionError, "not published to the production"):
            self.fixture.promote(
                self.job, self.publication, self.artifact_root,
                self.root / "unpublished", "production", contract,
            )


if __name__ == "__main__":
    unittest.main()
