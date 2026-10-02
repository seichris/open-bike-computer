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

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import web_flasher_manifest as web


def inputs(target="WAVESHARE_AMOLED_175"):
    table = b"".join(struct.pack("<HBBII16sI", 0x50AA, kind, subtype, start, size, name.encode(), 0)
                     for name, kind, subtype, start, size in web.PARTITIONS)
    table += b"\xeb\xeb" + b"\xff" * 14 + hashlib.md5(table).digest()
    table = table.ljust(0xC00, b"\xff")
    bootstrap = bytearray(b"\xff" * 8192)
    bootstrap[:4] = b"\x01\x00\x00\x00"
    bootstrap[28:32] = bytes.fromhex("9a984347")
    bootstrap[4096:4100] = b"\0" * 4
    images = {
        "images/00000000-bootloader.bin": b"\xe9" + b"bootloader" * 100,
        "images/00008000-partitions.bin": table,
        "images/0000e000-boot_app0.bin": bytes(bootstrap),
        "images/00010000-firmware.bin": b"\xe9" + b"application" * 1024,
    }
    descriptor = {"target": target, "environment": target + "_PRODUCTION",
                  "sourceIdentity": "a" * 40, "firmwareVersion": {"version": "0.3.5", "build": 100},
                  "flashPlan": {"flashCapacity": web.FLASH_BYTES, "images": [
                      {"file": name, "offset": hex(int(Path(name).name[:8], 16)),
                       "size": len(data), "sha256": web.digest(data)} for name, data in images.items()]}}
    return descriptor, images


class WebManifestTests(unittest.TestCase):
    def test_publisher_verifies_complete_factory_chain_and_is_create_only(self):
        import test_factory_release_manifest as factory_tests
        helper = factory_tests.FactoryReleaseManifestTests()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle, descriptor_path, _, key = helper.create_inputs(root)
            descriptor = json.loads(descriptor_path.read_text())
            factory = root / f"{factory_tests.TARGET}.factory"
            sample, images = inputs()
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
                self.assertEqual(len(list(args.output_dir.iterdir())), 3)
                envelope = json.loads((args.output_dir / f"{factory_tests.TARGET}.web-recovery.json").read_text())
                payload = json.loads(base64.b64decode(envelope["payload"]))
                self.assertEqual(payload["factoryDescriptorSha256"], web.digest(descriptor_path.read_bytes()))
                with self.assertRaisesRegex(ValueError, "create-only"):
                    web.publish(args)
                descriptor["sourceIdentity"] = "0" * 40
                descriptor_path.write_bytes(web.canonical(descriptor))
                args.output_dir = root / "tampered"
                with self.assertRaises(ValueError):
                    web.publish(args)
                self.assertFalse(args.output_dir.exists())

    def test_both_boards_preserve_all_non_recovery_regions(self):
        for target in ("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"):
            value, assets = web.recovery_payload(*inputs(target))
            self.assertEqual([v["offset"] for v in value["writes"]], [0x10000, 0xE000])
            self.assertEqual(len(assets), 2)
            self.assertEqual({r["name"] for r in value["regions"] if not r["preserve"]}, {"app0", "otadata"})
            self.assertEqual(value["unknownBuildPolicy"], "deny")
            self.assertTrue(value["qualificationRequired"])

    def test_layout_and_checksum_rejected(self):
        _, images = inputs()
        table = images["images/00008000-partitions.bin"]
        for offset in (0, 8, 0xC0 + 16, 0xE0):
            bad = bytearray(table)
            bad[offset] ^= 1
            with self.assertRaises(ValueError):
                web.partition_inventory(bytes(bad))

    def test_signed_wrong_offsets_and_protected_region_writes_rejected(self):
        descriptor, images = inputs()
        for field, value in (("offset", "0x9000"), ("size", True), ("sha256", "0" * 64)):
            bad = copy.deepcopy(descriptor)
            bad["flashPlan"]["images"][-1][field] = value
            with self.assertRaises(ValueError):
                web.recovery_payload(bad, images)

    def test_changed_bootstrap_and_slot_overflow_rejected(self):
        for suffix, raw in (("boot_app0.bin", b"\xff" * 8192), ("firmware.bin", b"\xe9" * 0x300000)):
            descriptor, images = inputs()
            record = next(r for r in descriptor["flashPlan"]["images"] if r["file"].endswith(suffix))
            images[record["file"]] = raw
            record.update(size=len(raw), sha256=web.digest(raw))
            with self.assertRaises(ValueError):
                web.recovery_payload(descriptor, images)

    def test_domain_separated_p1363_signature(self):
        payload, _ = web.recovery_payload(*inputs())
        key = ec.derive_private_key(1, ec.SECP256R1())  # public test key only
        envelope = web.sign(payload, base64.b64encode((1).to_bytes(32, "big")).decode())
        raw = base64.b64decode(envelope["signature"])
        self.assertEqual(len(raw), 64)
        der = utils.encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        key.public_key().verify(der, web.DOMAIN + web.canonical(payload), ec.ECDSA(hashes.SHA256()))
        with self.assertRaises(Exception):
            key.public_key().verify(der, web.canonical(payload), ec.ECDSA(hashes.SHA256()))

    def test_golden_vector(self):
        path = Path(__file__).parents[1] / "web-flasher" / "test-vector.json"
        if not path.exists():
            self.fail("cross-language vector missing")
        vector = json.loads(path.read_text())
        payload, _ = web.recovery_payload(*inputs())
        payload.update(factoryArchiveSha256="b" * 64, releaseTag="v0.3.5")
        self.assertEqual(base64.b64decode(vector["envelope"]["payload"]), web.canonical(payload))


if __name__ == "__main__":
    unittest.main()
