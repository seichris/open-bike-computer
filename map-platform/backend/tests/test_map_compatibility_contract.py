"""Durable map compatibility contract v1 and its frozen producer corpus.

The corpus under ``fixtures/map-compatibility-v1`` was produced once by the
real packaging, promotion and signing code (``map_compatibility_fixture.py``).
These tests pin its exact bytes, then check that the current backend still
reads every frozen map and gives direct-job and catalog delivery the same
compatibility meaning. Never regenerate the corpus to make a test pass.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from cryptography.hazmat.primitives.asymmetric import ec

from map_platform.artifacts import (
    BIKE_MAP_STREAM_FORMAT,
    TOPOGRAPHY_COMPANION_FORMAT,
    ArtifactRecord,
)
from map_platform.catalog import publication_payload
from map_platform.map_compatibility import (
    MapCompatibilityError,
    load_map_compatibility_contract,
    manifest_contract,
    parse_map_compatibility_contract,
    request_profile,
    require_contract_signer,
)
from map_platform.map_signing import P256MapArtifactSigner
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
from map_platform.models import JobStatus, MapJob
from map_platform.topography_companion import validate_companion


TESTS = Path(__file__).resolve().parent
REPO = TESTS.parents[2]
CORPUS = TESTS / "fixtures" / "map-compatibility-v1"
CONTRACT = REPO / "map-platform" / "config" / "map-compatibility-contract-v1.json"
# Pinned once when the corpus was frozen. A changed index means old fixtures
# were rewritten; add a new corpus directory for a later contract instead.
CORPUS_JSON_SHA256 = "9755ab855441cb0f91bde414e43e84f59756aa34d6c8a2f377f450797c37c35e"
CORPUS_INDEX_SHA256 = "d4a04b11b671bf453cb260167f09ee1cc8333235cde1c3461e8fbccf7379fd0f"
# Contract v1 as first published. Profiles and channels may be appended in a
# reviewed contract change; none of these may be removed or narrowed.
V1_PROFILES = {
    "buildings-3d-v1": (3, ("3d-buildings", "street-labels"), {"development", "production"}),
    "topographic-contours-v1": (
        4, ("3d-buildings", "contours", "street-labels"), {"development", "production"},
    ),
    "map-pois-v1": (5, ("3d-buildings", "map-pois", "street-labels"), {"development"}),
    "map-pois-contours-v1": (
        5, ("3d-buildings", "contours", "map-pois", "street-labels"), {"development"},
    ),
}


def load_corpus() -> dict:
    return json.loads((CORPUS / "corpus.json").read_text(encoding="utf-8"))


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
        for profile_id, (format_version, features, channels) in V1_PROFILES.items():
            with self.subTest(profile=profile_id):
                profile = profiles[profile_id]
                self.assertEqual(profile.renderer, "esp32-fmb")
                self.assertEqual(profile.renderer_format_version, format_version)
                self.assertEqual(profile.features, features)
                self.assertTrue(channels <= profile.channels)

    def test_parser_rejects_ambiguous_or_weakened_contracts(self):
        document = json.loads(CONTRACT.read_text(encoding="utf-8"))
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
            "revocation without compromise": lambda value: value.update(
                revokedSigners=[{
                    "keyId": "map-prod-2026-07", "publicKeySha256": "a" * 64,
                    "reason": "rotated",
                }]
            ),
            "revoked signer still registered": lambda value: value.update(
                revokedSigners=[{
                    "keyId": value["signers"][1]["keyId"],
                    "publicKeySha256": value["signers"][1]["publicKeySha256"],
                    "reason": "compromised",
                }]
            ),
        }
        for name, change in changes.items():
            with self.subTest(change=name):
                candidate = json.loads(json.dumps(document))
                change(candidate)
                with self.assertRaises(MapCompatibilityError):
                    parse_map_compatibility_contract(candidate)

    def test_registered_signers_stay_in_client_trust(self):
        contract = load_map_compatibility_contract()
        trusted = {
            (key.key_id, hashlib.sha256(bytes.fromhex(key.public_key_x963_hex)).hexdigest())
            for key in load_trust_registry(REPO / "map-platform" / "config" / "map-stream-trust.json")
            if key.state == "trusted"
        }
        settings = dict(
            line.split(" = ", 1)
            for line in (
                REPO / "ios-app" / "BikeComputer" / "Configuration" / "Development.xcconfig"
            ).read_text(encoding="utf-8").splitlines()
            if " = " in line
        )
        development = (
            settings["BICINO_MAP_DEVELOPMENT_SIGNING_KEY_ID"].strip(),
            hashlib.sha256(bytes.fromhex(
                settings["BICINO_MAP_DEVELOPMENT_SIGNING_PUBLIC_KEY_X963_HEX"].strip()
            )).hexdigest(),
        )
        for channel, key_id, key_sha256 in contract.signers:
            with self.subTest(signer=key_id):
                # Removing a durable signer from clients strands every map it
                # signed. Only a compromise revocation may do that.
                if channel == "production":
                    self.assertIn((key_id, key_sha256), trusted)
                else:
                    self.assertEqual((key_id, key_sha256), development)
        self.assertFalse(contract.revoked_signers & trusted)

    def test_generation_policies_never_publish_an_unregistered_durable_channel(self):
        contract = load_map_compatibility_contract()
        for path in sorted((REPO / "map-platform" / "config").glob("generation-profile-policy-v*.json")):
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

    def test_only_contract_profiles_without_experiments_are_marked(self):
        contract = load_map_compatibility_contract()

        def request(format_version, **target):
            return {"target": {
                "renderer": "esp32-fmb", "rendererFormatVersion": format_version, **target,
            }}

        self.assertIsNone(request_profile(request(1), contract))
        self.assertIsNone(request_profile(request(2), contract))
        self.assertEqual(request_profile(request(3), contract).profile_id, "buildings-3d-v1")
        self.assertEqual(
            request_profile(request(4), contract).profile_id, "topographic-contours-v1"
        )
        self.assertIsNone(request_profile(request(4, terrainProfileVersion=1), contract))
        self.assertEqual(
            request_profile(request(5, requestedFeatures=[
                "3d-buildings", "map-pois", "street-labels",
            ]), contract).profile_id,
            "map-pois-v1",
        )
        self.assertIsNone(request_profile({"target": None}, contract))

    def test_durable_manifest_requires_a_registered_signer_for_its_channel(self):
        contract = load_map_compatibility_contract()
        manifest = {"compatibility": {"contract": 1}}
        production = next(entry for entry in contract.signers if entry[0] == "production")
        self.assertEqual(
            require_contract_signer(manifest, "production", production[1], production[2], contract),
            1,
        )
        with self.assertRaisesRegex(MapCompatibilityError, "not a registered development"):
            require_contract_signer(manifest, "development", production[1], production[2], contract)
        with self.assertRaisesRegex(MapCompatibilityError, "not a registered production"):
            require_contract_signer(manifest, "production", production[1], "0" * 64, contract)
        with self.assertRaisesRegex(MapCompatibilityError, "unknown compatibility contract"):
            require_contract_signer(
                {"compatibility": {"contract": 2}}, "production",
                production[1], production[2], contract,
            )
        self.assertIsNone(require_contract_signer({}, "production", "any", "0" * 64, contract))
        for marker in ({"contract": 0}, {"contract": "1"}, {"contract": 1, "extra": 1}, [1]):
            with self.subTest(marker=marker), self.assertRaises(MapCompatibilityError):
                manifest_contract({"compatibility": marker})

    def test_job_classification_survives_persistence_and_old_records(self):
        corpus = load_corpus()
        entry = corpus["maps"][0]
        job = MapJob.from_dict(self.job_document(entry))
        self.assertEqual(job.compatibility_contract, 1)
        persisted = job.to_dict(include_internal=True)
        self.assertEqual(persisted["compatibilityContract"], 1)
        self.assertNotIn("compatibilityContract", job.to_dict())
        legacy = self.job_document(entry)
        legacy.pop("compatibilityContract")
        self.assertIsNone(MapJob.from_dict(legacy).compatibility_contract)
        for invalid in (0, "1", True, 256):
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                MapJob.from_dict(dict(legacy, compatibilityContract=invalid))

    @staticmethod
    def job_document(entry: dict) -> dict:
        return {
            "jobId": entry["jobId"],
            "status": "ready",
            "request": {"target": {
                "renderer": "esp32-fmb",
                "rendererFormatVersion": entry["rendererFormatVersion"],
            }},
            "geometry": {"mode": "custom_bbox", "bounds": [0.001, 0.001, 0.03, 0.03],
                         "areaKm2": 10, "vertexCount": 4},
            "sourceRegion": {"id": "fixture", "provider": "test", "name": "Fixture",
                             "url": "https://example.invalid/fixture.osm.pbf",
                             "bounds": [-1, -1, 1, 1]},
            "createdAt": "2026-10-26T00:00:00Z",
            "updatedAt": "2026-10-26T00:00:00Z",
            "mapId": entry["mapId"],
            "artifacts": entry["development"]["artifacts"],
            "compatibilityContract": entry["compatibilityContract"],
        }


class FrozenCorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.corpus = load_corpus()
        cls.signers = {value["keyId"]: value for value in cls.corpus["signers"]}

    def test_corpus_bytes_are_frozen(self):
        self.assertEqual(
            hashlib.sha256((CORPUS / "corpus.json").read_bytes()).hexdigest(),
            CORPUS_JSON_SHA256,
        )
        self.assertEqual(
            hashlib.sha256((CORPUS / "corpus.txt").read_bytes()).hexdigest(),
            CORPUS_INDEX_SHA256,
        )
        expected = self.corpus["files"]
        present = {
            path.name for path in CORPUS.iterdir()
            if path.name not in {"corpus.json", "corpus.txt", "README.md"}
        }
        self.assertEqual(present, set(expected))
        for name, sha256 in expected.items():
            with self.subTest(file=name):
                self.assertEqual(hashlib.sha256((CORPUS / name).read_bytes()).hexdigest(), sha256)

    def test_corpus_covers_every_contract_profile_and_channel(self):
        contract = load_map_compatibility_contract()
        maps = {entry["profile"]: entry for entry in self.corpus["maps"]}
        for profile in contract.profiles:
            with self.subTest(profile=profile.profile_id):
                entry = maps[profile.profile_id]
                self.assertEqual(entry["rendererFormatVersion"], profile.renderer_format_version)
                self.assertEqual(tuple(entry["features"]), profile.features)
                self.assertEqual(bool(entry["production"]), "production" in profile.channels)
                self.assertEqual(entry["companionFile"] is not None, bool(profile.companions))
        for key_id, signer in self.signers.items():
            self.assertIn(key_id, FORBIDDEN_FIXTURE_KEY_IDS)
            self.assertIn(signer["publicKeyX963Hex"], FORBIDDEN_FIXTURE_PUBLIC_KEYS)

    def test_every_frozen_stream_still_verifies_and_declares_its_profile(self):
        contract = load_map_compatibility_contract()
        for entry in self.corpus["maps"]:
            for variant in [entry["development"], *entry["production"]]:
                with self.subTest(file=variant["file"]):
                    data = (CORPUS / variant["file"]).read_bytes()
                    header, manifest, envelope, parsed = stream_parts(data)
                    stream = next(
                        value for value in variant["publication"]["artifacts"]
                        if value["format"] == BIKE_MAP_STREAM_FORMAT
                    )
                    signer = self.signers[stream["signatureKeyId"]]
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
                    self.assertEqual(
                        contract.profile_for(
                            parsed["target"]["renderer"], parsed["target"]["formatVersion"],
                            entry["features"],
                        ).profile_id,
                        entry["profile"],
                    )
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

    def test_corrupt_truncated_and_untrusted_streams_are_rejected(self):
        entry = self.corpus["maps"][0]
        data = (CORPUS / entry["development"]["file"]).read_bytes()
        header, manifest, envelope, _parsed = stream_parts(data)
        other_key = next(
            value["publicKeyX963Hex"] for key_id, value in self.signers.items()
            if value["channel"] == "production"
        )
        self.assertFalse(verify_signature(manifest, envelope, other_key))
        tampered = bytearray(manifest)
        tampered[-2] ^= 1
        development_key = self.signers["map-compat-fixture-dev-1"]["publicKeyX963Hex"]
        self.assertFalse(verify_signature(bytes(tampered), envelope, development_key))
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
        for entry in self.corpus["maps"]:
            if entry["companionFile"] is None:
                continue
            with self.subTest(profile=entry["profile"]):
                _header, _manifest, _envelope, parsed = stream_parts(
                    (CORPUS / entry["development"]["file"]).read_bytes()
                )
                with tempfile.TemporaryDirectory() as temporary:
                    path = Path(temporary) / f"{entry['mapId']}.btopo"
                    path.write_bytes((CORPUS / entry["companionFile"]).read_bytes())
                    metadata = validate_companion(
                        path, expected_map_id=entry["mapId"],
                        expected_intermediate=parsed["topography"]["intermediateSha256"],
                    )
                self.assertEqual(
                    metadata["attributionSha256"], parsed["topography"]["attributionSha256"]
                )
                companions = [
                    value
                    for variant in [entry["development"], *entry["production"]]
                    for value in variant["publication"]["artifacts"]
                    if value["format"] == TOPOGRAPHY_COMPANION_FORMAT
                ]
                self.assertEqual(len(companions), 1 + len(entry["production"]))
                self.assertEqual({value["sha256"] for value in companions},
                                 {self.corpus["files"][entry["companionFile"]]})

    def test_promotion_rotation_and_worker_update_keep_one_catalog_map(self):
        entry = next(value for value in self.corpus["maps"] if value["profile"] == "buildings-3d-v1")
        publications = [entry["development"]["publication"]] + [
            variant["publication"] for variant in entry["production"]
        ]
        self.assertEqual({value["mapEntryId"] for value in publications}, {entry["mapEntryId"]})
        self.assertEqual({value["contentReceipt"] for value in publications}, {entry["contentReceipt"]})
        streams = {
            variant["variant"]: next(
                value for value in variant["publication"]["artifacts"]
                if value["format"] == BIKE_MAP_STREAM_FORMAT
            )
            for variant in entry["production"]
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
        cls.corpus = load_corpus()

    def frozen_job(self, entry: dict) -> MapJob:
        return MapJob.from_dict(MapCompatibilityContractFileTests.job_document(entry))

    def test_current_publisher_reproduces_frozen_catalog_meaning(self):
        for entry in self.corpus["maps"]:
            with self.subTest(profile=entry["profile"]):
                job = self.frozen_job(entry)
                job.request = self.request_for(entry)
                frozen = entry["development"]["publication"]
                with patch.dict(os.environ, self.FIRMWARE_GATE):
                    current = publication_payload(self.ready(job, frozen), "development")
                self.assertEqual(
                    {value["artifactId"]: value for value in current["artifacts"]},
                    {value["artifactId"]: value for value in frozen["artifacts"]},
                )
                self.assertEqual(current["mapEntryId"], frozen["mapEntryId"])

    def test_pre_baseline_maps_keep_their_configured_firmware_gate(self):
        entry = self.corpus["maps"][0]
        job = self.ready(self.frozen_job(entry), entry["development"]["publication"])
        job.request = self.request_for(entry)
        job.compatibility_contract = None
        with patch.dict(os.environ, self.FIRMWARE_GATE):
            payload = publication_payload(job, "development")
        stream = next(
            value for value in payload["artifacts"] if value["format"] == BIKE_MAP_STREAM_FORMAT
        )
        self.assertEqual(stream["requiredFirmwareBuild"], 104)

    def test_rollout_keeps_earlier_approved_durable_maps_after_a_worker_update(self):
        entry = next(value for value in self.corpus["maps"] if value["profile"] == "buildings-3d-v1")
        production = {variant["variant"]: variant for variant in entry["production"]}
        original = self.stream(production["production"])
        updated = self.stream(production["production-updated-worker"])
        rotated = self.stream(production["production-rotated-key"])
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

        def allowed(stream, contract, trust=signers):
            return policy.allows_artifact(
                installation, stream["signatureKeyId"], stream["signatureKeySha256"],
                stream["producerBuildSha256"], stream["producerImageDigest"],
                frozenset(trust), None, None, None, compatibility_contract=contract,
            )

        for stream in (original, updated, rotated):
            with self.subTest(producer=stream["producerBuildSha256"][:8],
                              key=stream["signatureKeyId"]):
                self.assertTrue(allowed(stream, 1))
        # Pre-baseline maps keep the single-approval rule.
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
        self.assertFalse(revoked.allows_artifact(
            installation, original["signatureKeyId"], original["signatureKeySha256"],
            original["producerBuildSha256"], original["producerImageDigest"],
            frozenset(signers), None, None, None, compatibility_contract=1,
        ))
        self.assertEqual(policy.artifact_delivery_requirements(compatibility_contract=1), {})
        self.assertEqual(
            policy.artifact_delivery_requirements(compatibility_contract=None)[
                "requiredFirmwareBuild"
            ],
            105,
        )

    @staticmethod
    def stream(variant: dict) -> dict:
        return next(
            value for value in variant["publication"]["artifacts"]
            if value["format"] == BIKE_MAP_STREAM_FORMAT
        )

    @staticmethod
    def request_for(entry: dict) -> dict:
        target = {
            "renderer": "esp32-fmb",
            "rendererFormatVersion": entry["rendererFormatVersion"],
            "firmwareVersion": "0.3.4",
        }
        if entry["rendererFormatVersion"] == 5:
            target["requestedFeatures"] = entry["features"]
        return {
            "target": target,
            "labels": {"profileVersion": 1, "preferredLanguages": ["en"],
                       "internationalFallback": "en"},
        }

    @staticmethod
    def ready(job: MapJob, publication: dict) -> MapJob:
        job.status = JobStatus.READY
        job.finished_at = publication["generatedAt"]
        job.source_region = replace(
            job.source_region,
            name=publication["sourceRegionName"],
            provider=publication["attribution"]["provider"],
            license=publication["attribution"].get("license"),
        )
        return job


class PromotionTests(unittest.TestCase):
    """Production promotion keeps a durable map durable and ungated."""

    @classmethod
    def setUpClass(cls):
        from tests import map_compatibility_fixture as fixture

        cls.fixture = fixture
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.contract = fixture.fixture_contract()
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
        stream = next(
            value for value in publication["artifacts"]
            if value["format"] == BIKE_MAP_STREAM_FORMAT
        )
        self.assertEqual(publication["contentReceipt"], self.publication["contentReceipt"])
        for field in ("requiredFirmwareVersion", "requiredFirmwareBuild", "requiredFirmwareGitSha"):
            self.assertNotIn(field, stream)

    def test_promotion_refuses_an_unregistered_production_signer(self):
        from map_platform.catalog_promotion import CatalogPromotionError

        contract = replace(self.contract, signers=frozenset(
            value for value in self.contract.signers if value[0] == "development"
        ))
        with self.assertRaisesRegex(CatalogPromotionError, "not a registered production"):
            self.fixture.promote(
                self.job, self.publication, self.artifact_root,
                self.root / "rogue", "production", contract,
            )


class ProducerGuardTests(unittest.TestCase):
    def test_unregistered_key_cannot_sign_a_durable_map(self):
        contract = load_map_compatibility_contract()
        rogue = P256MapArtifactSigner("map-prod-rogue", ec.derive_private_key(99, ec.SECP256R1()))
        with self.assertRaisesRegex(MapCompatibilityError, "not a registered production"):
            require_contract_signer(
                {"compatibility": {"contract": 1}}, "production",
                rogue.key_id, rogue.public_key_sha256, contract,
            )

    def test_development_only_profile_is_not_published_to_production(self):
        contract = load_map_compatibility_contract()
        profile = contract.profile_for("esp32-fmb", 5, ("3d-buildings", "map-pois", "street-labels"))
        contract.require_publishable(profile, "development")
        with self.assertRaisesRegex(MapCompatibilityError, "not published to the production"):
            contract.require_publishable(profile, "production")


if __name__ == "__main__":
    unittest.main()
