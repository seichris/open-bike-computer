import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from map_platform.building_cache_receipts import (
    BuildingBlockReceiptError,
    read_building_block_receipt,
)
from map_platform.building_scope import canonical_json
from map_platform.reuse import MapBlock


class BuildingCacheReceiptTests(unittest.TestCase):
    def test_reads_and_validates_published_manifest_and_section(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_sha = "a" * 64
            rules_sha = "b" * 64
            identity_body = {
                "sourceSnapshotSha256": source_sha,
                "rulesSha256": rules_sha,
                "blockGridVersion": 1,
            }
            identity_sha = hashlib.sha256(canonical_json(identity_body)).hexdigest()
            identity = {**identity_body, "cacheIdentitySha256": identity_sha}
            namespace = root / "building-block-v1" / source_sha / rules_sha / identity_sha
            section = b"canonical-fmb-section"
            section_sha = hashlib.sha256(section).hexdigest()
            stats = {"recordCount": 0, "sectionBytes": len(section)}
            manifest_body = {
                "schemaVersion": 1,
                "cacheIdentitySha256": identity_sha,
                "block": {
                    "x": 12,
                    "y": 34,
                    "boundsMeters": [49152, 139264, 53248, 143360],
                },
                "section": {
                    "path": f"sections/{section_sha}.bin",
                    "bytes": len(section),
                    "sha256": section_sha,
                },
                "stats": stats,
            }
            manifest = {
                **manifest_body,
                "manifestSha256": hashlib.sha256(
                    canonical_json(manifest_body)
                ).hexdigest(),
            }
            (namespace / "blocks").mkdir(parents=True)
            (namespace / "sections").mkdir()
            (namespace / "sections" / f"{section_sha}.bin").write_bytes(section)
            (namespace / "blocks" / "12_34.json").write_bytes(
                canonical_json(manifest)
            )

            receipt = read_building_block_receipt(
                root, identity, MapBlock(12, 34)
            )

            self.assertEqual(receipt.content_sha256, section_sha)
            self.assertEqual(receipt.content_bytes, len(section))
            self.assertEqual(receipt.stats, stats)

    def test_corrupt_section_is_not_publishable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_sha = "a" * 64
            rules_sha = "b" * 64
            identity_body = {
                "sourceSnapshotSha256": source_sha,
                "rulesSha256": rules_sha,
            }
            identity_sha = hashlib.sha256(canonical_json(identity_body)).hexdigest()
            identity = {**identity_body, "cacheIdentitySha256": identity_sha}
            namespace = root / "building-block-v1" / source_sha / rules_sha / identity_sha
            section = b"section"
            section_sha = hashlib.sha256(section).hexdigest()
            body = {
                "schemaVersion": 1,
                "cacheIdentitySha256": identity_sha,
                "block": {
                    "x": 1,
                    "y": 2,
                    "boundsMeters": [4096, 8192, 8192, 12288],
                },
                "section": {
                    "path": f"sections/{section_sha}.bin",
                    "bytes": len(section),
                    "sha256": section_sha,
                },
                "stats": {"recordCount": 0, "sectionBytes": len(section)},
            }
            namespace.joinpath("blocks").mkdir(parents=True)
            namespace.joinpath("sections").mkdir()
            namespace.joinpath("sections", f"{section_sha}.bin").write_bytes(b"tampered")
            namespace.joinpath("blocks", "1_2.json").write_bytes(
                canonical_json(
                    {
                        **body,
                        "manifestSha256": hashlib.sha256(
                            canonical_json(body)
                        ).hexdigest(),
                    }
                )
            )
            with self.assertRaises(BuildingBlockReceiptError) as raised:
                read_building_block_receipt(root, identity, MapBlock(1, 2))
            self.assertEqual(raised.exception.code, "building_block_cache_invalid")


if __name__ == "__main__":
    unittest.main()
