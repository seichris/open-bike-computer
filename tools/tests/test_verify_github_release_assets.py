from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools.verify_github_release_assets import verify_release_assets


class VerifyGithubReleaseAssetsTests(unittest.TestCase):
    def test_requires_exact_server_digests_and_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            assets = root / "assets"
            assets.mkdir()
            artifact = assets / "firmware.bin"
            artifact.write_bytes(b"firmware")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            release = root / "release.json"
            release.write_text(
                json.dumps(
                    {
                        "id": 42,
                        "tag_name": "v1.2.3",
                        "immutable": True,
                        "assets": [
                            {
                                "name": artifact.name,
                                "size": artifact.stat().st_size,
                                "digest": f"sha256:{digest}",
                                "state": "uploaded",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            receipt = verify_release_assets(
                release, assets, require_immutable=True
            )

            self.assertEqual("v1.2.3", receipt["tag"])
            self.assertTrue(receipt["immutable"])
            self.assertEqual(digest, receipt["assets"][0]["sha256"])

    def test_rejects_missing_digest_extra_asset_and_local_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            assets = root / "assets"
            assets.mkdir()
            artifact = assets / "firmware.bin"
            artifact.write_bytes(b"firmware")
            release = root / "release.json"
            release.write_text(
                json.dumps(
                    {
                        "id": 42,
                        "tag_name": "v1.2.3",
                        "immutable": False,
                        "assets": [
                            {
                                "name": artifact.name,
                                "size": artifact.stat().st_size,
                                "digest": None,
                                "state": "uploaded",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "asset is invalid"):
                verify_release_assets(release, assets)

            release_value = json.loads(release.read_text(encoding="utf-8"))
            release_value["assets"][0]["digest"] = "sha256:" + hashlib.sha256(
                artifact.read_bytes()
            ).hexdigest()
            release_value["assets"].append(
                {
                    "name": "unexpected.bin",
                    "size": 1,
                    "digest": "sha256:" + "0" * 64,
                    "state": "uploaded",
                }
            )
            release.write_text(json.dumps(release_value), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "do not exactly match"):
                verify_release_assets(release, assets)

            release_value["assets"].pop()
            release.write_text(json.dumps(release_value), encoding="utf-8")
            (assets / "linked.bin").symlink_to(artifact)
            with self.assertRaisesRegex(ValueError, "local release asset is unsafe"):
                verify_release_assets(release, assets)

    def test_rejects_mutable_release_when_immutability_is_required(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            assets = root / "assets"
            assets.mkdir()
            artifact = assets / "firmware.bin"
            artifact.write_bytes(b"firmware")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            release = root / "release.json"
            release.write_text(
                json.dumps(
                    {
                        "id": 42,
                        "tag_name": "v1.2.3",
                        "immutable": False,
                        "assets": [
                            {
                                "name": artifact.name,
                                "size": artifact.stat().st_size,
                                "digest": f"sha256:{digest}",
                                "state": "uploaded",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "release is not immutable"):
                verify_release_assets(
                    release, assets, require_immutable=True
                )


if __name__ == "__main__":
    unittest.main()
