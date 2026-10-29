from __future__ import annotations

import base64
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
from argparse import Namespace
from unittest.mock import patch
import unittest

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import web_flasher_manifest as web

VECTOR_DIR = Path(__file__).parents[1] / "web-flasher"
MIGRATION_VECTOR = VECTOR_DIR / "migration-test-vector.json"
TEST_SCALAR = base64.b64encode((1).to_bytes(32, "big")).decode()  # public test key only


def inputs(target="WAVESHARE_AMOLED_175", firmware=None, table=None):
    bootstrap = bytearray(b"\xff" * 8192)
    bootstrap[:4] = b"\x01\x00\x00\x00"
    bootstrap[28:32] = bytes.fromhex("9a984347")
    bootstrap[4096:4100] = b"\0" * 4
    images = {
        "images/00000000-bootloader.bin": b"\xe9" + b"bootloader" * 100,
        "images/00008000-partitions.bin": web.CURRENT.table_bytes() if table is None else table,
        "images/0000e000-boot_app0.bin": bytes(bootstrap),
        "images/00010000-firmware.bin": b"\xe9" + b"application" * 1024 if firmware is None else firmware,
    }
    descriptor = {"target": target, "environment": target + "_PRODUCTION",
                  "sourceIdentity": "a" * 40, "firmwareVersion": {"version": "0.3.5", "build": 100},
                  "flashPlan": {"flashCapacity": web.FLASH_BYTES, "images": [
                      {"file": name, "offset": hex(int(Path(name).name[:8], 16)),
                       "size": len(data), "sha256": web.digest(data)} for name, data in images.items()]}}
    return descriptor, images


def with_release(payload):
    return dict(payload, factoryArchiveSha256="b" * 64, releaseTag="v0.3.5")


def build_vector() -> dict:
    """Deterministic payloads; regenerate with --write-vector after a reviewed change."""
    descriptor, images = inputs()
    payloads, assets = web.release_packages(descriptor, images)
    key = ec.derive_private_key(1, ec.SECP256R1())
    public = key.public_key().public_bytes(serialization.Encoding.DER,
                                           serialization.PublicFormat.SubjectPublicKeyInfo)
    legacy_app = b"\xe9" + b"legacy-development-app" * 600
    return {
        "notice": "Public test key only; never a production trust anchor.",
        "publicKey": base64.b64encode(public).decode(),
        "packages": {name: web.sign(with_release(payload), TEST_SCALAR) for name, payload in payloads.items()},
        "assets": {name: base64.b64encode(data).decode() for name, data in sorted(assets.items())},
        # A generation-1 device: bootloader, dual-3-MiB table, app0 selection
        # and an unidentified development image in app0.
        "legacyDevice": {
            "00000000": base64.b64encode(images["images/00000000-bootloader.bin"]).decode(),
            "00008000": base64.b64encode(web.LEGACY.table_bytes()).decode(),
            "0000e000": base64.b64encode(images["images/0000e000-boot_app0.bin"]).decode(),
            "00010000": base64.b64encode(legacy_app).decode(),
        },
        "layouts": json.loads(web.partition_layouts.REGISTRY_PATH.read_text()),
    }


def verify_envelope(envelope: dict, public_key_base64: str) -> dict:
    payload = base64.b64decode(envelope["payload"])
    raw = base64.b64decode(envelope["signature"])
    der = utils.encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    key = serialization.load_der_public_key(base64.b64decode(public_key_base64))
    key.verify(der, web.DOMAIN + payload, ec.ECDSA(hashes.SHA256()))
    return json.loads(payload)


class WebManifestTests(unittest.TestCase):
    def publish_case(self, firmware=None):
        import test_factory_release_manifest as factory_tests
        helper = factory_tests.FactoryReleaseManifestTests()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle, descriptor_path, _, key = helper.create_inputs(root)
            descriptor = json.loads(descriptor_path.read_text())
            factory = root / f"{factory_tests.TARGET}.factory"
            sample, images = inputs(firmware=firmware)
            for old in (factory / "images").iterdir():
                old.unlink()
            for name, data in images.items():
                (factory / name).write_bytes(data)
            descriptor["flashPlan"]["images"] = sample["flashPlan"]["images"]
            descriptor["flashPlan"]["flashCapacity"] = web.FLASH_BYTES
            merged = bytearray(b"\xff" * max(int(r["offset"], 16) + r["size"] for r in sample["flashPlan"]["images"]))
            for record in sample["flashPlan"]["images"]:
                offset = int(record["offset"], 16)
                merged[offset:offset + record["size"]] = images[record["file"]]
            merged_path = factory / descriptor["flashPlan"]["mergedImage"]["file"]
            merged_path.write_bytes(merged)
            descriptor["flashPlan"]["mergedImage"].update(size=len(merged), sha256=web.digest(merged))
            attestation_path = factory / "attestation/build-manifest.json"
            attestation = json.loads(attestation_path.read_text())
            attested_plan = attestation["flashPlan"]
            attested_plan["images"] = [
                {"offset": r["offset"], "size": r["size"], "sha256": r["sha256"],
                 "path": "/verified/" + Path(r["file"]).name.split("-", 1)[1]}
                for r in sample["flashPlan"]["images"]]
            attested_plan["command"] = attested_plan["command"][:-8] + [item for r in attested_plan["images"] for item in (r["offset"], r["path"])]
            plan_digest = web.digest(web.canonical(attested_plan).rstrip(b"\n"))
            attestation["flashPlanSha256"] = plan_digest
            attestation_path.write_bytes(web.canonical(attestation))
            descriptor["buildAttestation"].update(size=attestation_path.stat().st_size, sha256=web.digest(attestation_path.read_bytes()), flashPlanSha256=plan_digest)
            descriptor_path.write_bytes(web.canonical(descriptor))
            (factory / "factory-bundle.json").write_bytes(descriptor_path.read_bytes())
            helper.write_checksums(factory)
            helper.write_archive(bundle, factory)
            args = Namespace(bundle=bundle, bundle_manifest=descriptor_path, target=factory_tests.TARGET,
                             git_sha=factory_tests.GIT_SHA, version="2.3.4", build=57, tag="v2.3.4", output_dir=root / "web")
            with patch.dict("os.environ", {"FIRMWARE_MANIFEST_SIGNING_PRIVATE_KEY": key}):
                web.publish(args)
                names = sorted(path.name for path in args.output_dir.iterdir())
                manifests = web.asset_names(factory_tests.TARGET)
                firmware = images["images/00010000-firmware.bin"]
                fits = len(firmware) <= web.LEGACY.max_application_bytes
                published = [name for kind, name in manifests.items() if fits or kind != "legacy-recovery"]
                # The signed recipes, the signed image identity and three
                # content-addressed images (application, OTA bootstrap and
                # destination table).
                self.assertEqual(len(names), len(published) + 4)
                self.assertTrue(set(published) <= set(names))
                self.assertEqual(manifests["legacy-recovery"] in names, fits)
                for name in published:
                    envelope = json.loads((args.output_dir / name).read_text())
                    payload = json.loads(base64.b64decode(envelope["payload"]))
                    self.assertEqual(payload["factoryDescriptorSha256"], web.digest(descriptor_path.read_bytes()))
                    self.assertEqual(payload["releaseTag"], "v2.3.4")
                # Bound to the dual-4-MiB rescue, which every release carries.
                recovery = json.loads(base64.b64decode(json.loads(
                    (args.output_dir / manifests["recovery"]).read_text())["payload"]))
                identity_envelope = json.loads(
                    (args.output_dir / f"{factory_tests.TARGET}.image-identity.json").read_text())
                identity = json.loads(base64.b64decode(identity_envelope["payload"]))
                self.assertEqual(identity, web.identity_payload(recovery, firmware))
                self.assertEqual((identity["releaseTag"], identity["build"], identity["image"]["sha256"]),
                                 ("v2.3.4", 57, recovery["writes"][0]["sha256"]))
                with self.assertRaisesRegex(ValueError, "create-only"):
                    web.publish(args)
                descriptor["sourceIdentity"] = "0" * 40
                descriptor_path.write_bytes(web.canonical(descriptor))
                args.output_dir = root / "tampered"
                with self.assertRaises(ValueError):
                    web.publish(args)
                self.assertFalse(args.output_dir.exists())

    def test_publisher_verifies_complete_factory_chain_and_is_create_only(self):
        self.publish_case()

    def test_identity_is_published_when_the_legacy_rescue_is_omitted(self):
        self.publish_case(firmware=b"\xe9" + bytes(web.LEGACY.max_application_bytes))

    def test_both_layout_recoveries_preserve_all_non_recovery_regions(self):
        for target in ("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"):
            for layout, flasher in ((web.LEGACY, 2), (web.CURRENT, 3)):
                value, assets = web.recovery_payload(*inputs(target), layout)
                self.assertEqual([v["offset"] for v in value["writes"]], [0x10000, 0xE000])
                self.assertEqual(len(assets), 2)
                self.assertEqual({r["name"] for r in value["regions"] if not r["preserve"]}, {"app0", "otadata"})
                self.assertEqual(value["layoutId"], layout.id)
                self.assertEqual(value["partitionTableSha256"], layout.table_sha256)
                self.assertEqual(value["minFlasherVersion"], flasher)
                self.assertEqual(value["unknownBuildPolicy"], "rescue")
                self.assertFalse(value["qualificationRequired"])

    def test_legacy_recovery_payload_keeps_the_published_contract(self):
        """A new release can still rescue a dual-3-MiB device without migrating it."""
        rescue = json.loads((VECTOR_DIR / "rescue-test-vector.json").read_text())
        published = verify_envelope(rescue["envelope"], rescue["publicKey"])
        current = with_release(web.recovery_payload(*inputs())[0])
        # Only the factory descriptor (now carrying the dual-4-MiB table) differs.
        self.assertEqual({k for k in published if published[k] != current[k]}, {"factoryDescriptorSha256"})
        self.assertEqual(set(published), set(current))
        for name in ("test-vector.json", "rescue-test-vector.json"):
            vector = json.loads((VECTOR_DIR / name).read_text())
            payload = verify_envelope(vector["envelope"], vector["publicKey"])
            self.assertEqual(payload["layoutId"], web.LEGACY.id)
            self.assertEqual(payload["regions"], web._regions(web.LEGACY))

    def test_layout_and_checksum_rejected(self):
        for layout in (web.LEGACY, web.CURRENT):
            table = layout.table_bytes()
            for offset in (0, 8, 0xC0 + 16, 0xE0):
                bad = bytearray(table)
                bad[offset] ^= 1
                with self.assertRaises(ValueError):
                    web.partition_inventory(bytes(bad), layout)
        with self.assertRaises(ValueError):
            web.partition_inventory(web.LEGACY.table_bytes(), web.CURRENT)

    def test_release_must_carry_the_current_production_table(self):
        for table in (web.LEGACY.table_bytes(), web.LAYOUTS.current("development").table_bytes(), b"\xff" * 0xC00):
            with self.assertRaises(ValueError):
                web.release_packages(*inputs(table=table))

    def test_signed_wrong_offsets_and_protected_region_writes_rejected(self):
        descriptor, images = inputs()
        for field, value in (("offset", "0x9000"), ("size", True), ("sha256", "0" * 64)):
            bad = copy.deepcopy(descriptor)
            bad["flashPlan"]["images"][-1][field] = value
            with self.assertRaises(ValueError):
                web.release_packages(bad, images)

    def test_changed_bootstrap_and_slot_overflow_rejected(self):
        for suffix, raw in (("boot_app0.bin", b"\xff" * 8192),
                            ("firmware.bin", b"\xe9" * (web.CURRENT.max_application_bytes + 1))):
            descriptor, images = inputs()
            record = next(r for r in descriptor["flashPlan"]["images"] if r["file"].endswith(suffix))
            images[record["file"]] = raw
            record.update(size=len(raw), sha256=web.digest(raw))
            with self.assertRaises(ValueError):
                web.release_packages(descriptor, images)

    def test_legacy_recovery_is_omitted_once_the_image_outgrows_dual_3_mib(self):
        names = web.asset_names("WAVESHARE_AMOLED_206")
        for size, legacy in ((web.LEGACY.max_application_bytes, True),
                             (web.LEGACY.max_application_bytes + 1, False),
                             (web.CURRENT.max_application_bytes, False)):
            payloads, _ = web.release_packages(*inputs("WAVESHARE_AMOLED_206", firmware=b"\xe9" * size))
            self.assertEqual(names["legacy-recovery"] in payloads, legacy, size)
            self.assertIn(names["recovery"], payloads)
            self.assertIn(names["migration"], payloads)
            with self.assertRaises(ValueError) if not legacy else _nothing():
                web.recovery_payload(*inputs("WAVESHARE_AMOLED_206", firmware=b"\xe9" * size), web.LEGACY)

    def test_migration_recipe_is_ordered_bounded_and_gated(self):
        value, assets = web.migration_payload(*inputs())
        steps = value["steps"]
        self.assertEqual([s["role"] for s in steps],
                         ["application", "ota-selection", "erase-app1", "erase-ffat", "partition-table"])
        self.assertEqual([s["offset"] for s in steps], [0x10000, 0xE000, 0x410000, 0x810000, 0x8000])
        self.assertEqual(steps[2]["eraseLength"], 0x400000)
        self.assertEqual(steps[3]["eraseLength"], 0x700000)
        self.assertEqual(steps[3]["sha256"], hashlib.sha256(b"\xff" * 0x700000).hexdigest())
        self.assertEqual(steps[-1]["sha256"], web.CURRENT.table_sha256)
        self.assertEqual(steps[-1]["length"], 0xC00)
        self.assertEqual(steps[-1]["eraseLength"], 0x1000)
        self.assertEqual(value["source"]["partitionTableSha256"], web.LEGACY.table_sha256)
        self.assertEqual(value["destination"]["partitionTableSha256"], web.CURRENT.table_sha256)
        self.assertTrue(value["qualificationRequired"])
        self.assertEqual(value["minFlasherVersion"], 3)
        self.assertEqual(value["migrationId"], "dual3m-to-dual4m-v1")
        self.assertLessEqual(len(value["dataImpact"]), 500)
        # NVS (ownership, TLS identity, settings), bootloader and coredump are
        # never inside any erase span; everything else is rewritten or erased.
        preserved = [(p["offset"], p["offset"] + p["length"]) for p in value["preserve"]]
        self.assertEqual(preserved, [(0, 0x8000), (0x9000, 0xE000), (0xF10000, 0x1000000)])
        touched = sorted((s["offset"], s["offset"] + s["eraseLength"]) for s in steps)
        for start, end in touched:
            for keep_start, keep_end in preserved:
                self.assertTrue(end <= keep_start or start >= keep_end)
        # The destination app1 and FFat are erased completely, so neither the
        # old rollback image nor any shifted old FFat byte survives there.
        self.assertIn((0x410000, 0x810000), touched)
        self.assertIn((0x810000, 0xF10000), touched)
        for step in steps:
            if "asset" in step:
                self.assertEqual(web.digest(assets[step["asset"]]), step["sha256"])
                self.assertEqual(step["asset"], f"WAVESHARE_AMOLED_175.web-{step['sha256']}.bin")
            else:
                self.assertEqual(step["fill"], 255)

    def test_domain_separated_p1363_signature(self):
        payload, _ = web.recovery_payload(*inputs())
        key = ec.derive_private_key(1, ec.SECP256R1())  # public test key only
        envelope = web.sign(payload, TEST_SCALAR)
        raw = base64.b64decode(envelope["signature"])
        self.assertEqual(len(raw), 64)
        der = utils.encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        key.public_key().verify(der, web.DOMAIN + web.canonical(payload), ec.ECDSA(hashes.SHA256()))
        with self.assertRaises(Exception):
            key.public_key().verify(der, web.canonical(payload), ec.ECDSA(hashes.SHA256()))

    def test_golden_vectors(self):
        rescue = json.loads((VECTOR_DIR / "rescue-test-vector.json").read_text())
        vector = json.loads(MIGRATION_VECTOR.read_text())
        expected = build_vector()
        self.assertEqual(vector["publicKey"], rescue["publicKey"])
        self.assertEqual(vector["assets"], expected["assets"])
        self.assertEqual(vector["legacyDevice"], expected["legacyDevice"])
        self.assertEqual(vector["layouts"], expected["layouts"])
        self.assertEqual(set(vector["packages"]), set(expected["packages"]))
        for name, envelope in vector["packages"].items():
            payload = verify_envelope(envelope, vector["publicKey"])
            self.assertEqual(base64.b64decode(envelope["payload"]),
                             base64.b64decode(expected["packages"][name]["payload"]), name)
            self.assertEqual(payload["target"], "WAVESHARE_AMOLED_175")

    def signed_identity(self):
        payload, assets = web.recovery_payload(*inputs(), web.CURRENT)
        payload.update(factoryArchiveSha256="b" * 64, releaseTag="v0.3.5")
        return payload, assets[payload["writes"][0]["asset"]]

    def test_identity_binds_the_exact_signed_application(self):
        payload, firmware = self.signed_identity()
        identity = web.identity_payload(payload, firmware)
        self.assertEqual(identity["image"], {
            "size": len(firmware), "sha256": web.digest(firmware), "headLength": 4096,
            "headSha256": web.digest(firmware[:4096]), "tail": firmware[-32:].hex()})
        for field in ("target", "environment", "version", "build", "gitSha", "releaseTag"):
            self.assertEqual(identity[field], payload[field])
        self.assertIsNone(identity["descriptor"])
        with self.assertRaisesRegex(ValueError, "identity image"):
            web.identity_payload(payload, firmware + b"\0")

    def test_app_descriptor_is_informational_printable_ascii(self):
        image = bytearray(b"\xe9" + bytes(0x1FF))
        struct.pack_into("<I", image, 0x20, 0xABCD5432)
        image[0x30:0x38] = b"v1.2.3\x01\x80"
        image[0x50:0x55] = b"esp32"
        image[0xB0:0xD0] = bytes(range(32))
        self.assertEqual(web.app_descriptor(bytes(image)),
                         {"version": "v1.2.3??", "projectName": "esp32", "elfSha256": bytes(range(32)).hex()})
        image[0x20] ^= 1
        self.assertIsNone(web.app_descriptor(bytes(image)))
        self.assertIsNone(web.app_descriptor(b"\xe9" * 0x100))

    def test_identity_signature_is_domain_separated(self):
        payload, firmware = self.signed_identity()
        identity = web.identity_payload(payload, firmware)
        key = ec.derive_private_key(1, ec.SECP256R1())  # public test key only
        envelope = web.sign(identity, base64.b64encode((1).to_bytes(32, "big")).decode(), web.IDENTITY_DOMAIN)
        raw = base64.b64decode(envelope["signature"])
        der = utils.encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        key.public_key().verify(der, web.IDENTITY_DOMAIN + web.canonical(identity), ec.ECDSA(hashes.SHA256()))
        with self.assertRaises(Exception):
            key.public_key().verify(der, web.DOMAIN + web.canonical(identity), ec.ECDSA(hashes.SHA256()))

    def test_identity_golden_vector(self):
        path = Path(__file__).parents[1] / "web-flasher" / "identity-test-vector.json"
        if not path.exists():
            self.fail("cross-language identity vector missing")
        vector = json.loads(path.read_text())
        payload, firmware = self.signed_identity()
        data = base64.b64decode(vector["envelope"]["payload"])
        self.assertEqual(data, web.canonical(web.identity_payload(payload, firmware)))
        raw = base64.b64decode(vector["envelope"]["signature"])
        der = utils.encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        public = ec.derive_private_key(1, ec.SECP256R1()).public_key()
        public.verify(der, web.IDENTITY_DOMAIN + data, ec.ECDSA(hashes.SHA256()))


class _nothing:
    def __enter__(self):
        return self

    def __exit__(self, *error):
        return False


if __name__ == "__main__":
    if sys.argv[1:] == ["--write-vector"]:
        MIGRATION_VECTOR.write_text(json.dumps(build_vector(), indent=2, sort_keys=True) + "\n")
        raise SystemExit(0)
    unittest.main()
