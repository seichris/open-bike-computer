import hashlib
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from building_block_cache import (  # noqa: E402
    BuildingBlockCache,
    BuildingBlockCacheError,
    load_building_block_cache_identity,
)
from building_calibration_cache import canonical_json  # noqa: E402


def identity():
    body = {
        "schemaVersion": 1,
        "sourceSnapshotSha256": "1" * 64,
        "rulesSha256": "2" * 64,
        "buildingProfileVersion": 1,
        "rendererFormatVersion": 3,
        "fmbVersion": 4,
        "blockGridVersion": 1,
        "blockSizeMeters": 4096,
        "selectionSemantics": "complete_blocks_no_selection_edge_clipping",
        "geometryBufferMeters": 256,
        "relationRetryBufferMeters": 512,
        "maxGeometryBufferMeters": 2048,
        "normalizationAlgorithmVersion": 2,
        "blockEncodingAlgorithmVersion": 2,
        "geometryEngine": {"name": "shapely", "version": "2.0.7"},
        "sourceIndex": {"schemaVersion": 1, "algorithmVersion": 2},
        "closureAlgorithmVersion": 1,
        "calibration": {
            "algorithmVersion": 1,
            "calibrationKey": "3" * 64,
            "manifestSha256": "4" * 64,
            "entrySetSha256": "5" * 64,
        },
    }
    return {
        **body,
        "cacheIdentitySha256": hashlib.sha256(canonical_json(body)).hexdigest(),
    }


def stats(*, records=1, points=4, section_bytes=17):
    return {
        "recordCount": records,
        "pointCount": points,
        "emittedWallCount": 4 if records else 0,
        "suppressedWallCount": 0,
        "droppedHoleCount": 0,
        "explicitHeightCount": records,
        "levelsHeightCount": 0,
        "inheritedHeightCount": 0,
        "localMedianHeightCount": 0,
        "classDefaultHeightCount": 0,
        "sectionBytes": section_bytes,
    }


class BuildingBlockCacheTests(unittest.TestCase):
    def test_identity_is_canonical_and_hash_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "identity.json"
            value = identity()
            path.write_bytes(canonical_json(value))
            self.assertEqual(load_building_block_cache_identity(path), value)

            value["blockSizeMeters"] = 2048
            path.write_bytes(canonical_json(value))
            with self.assertRaisesRegex(BuildingBlockCacheError, "identity"):
                load_building_block_cache_identity(path)

    def test_materializes_content_addressed_section_and_reuses_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = BuildingBlockCache(tmp, identity())
            calls = 0
            payload = b"canonical-section"

            def build():
                nonlocal calls
                calls += 1
                return payload, stats(section_bytes=len(payload))

            first = cache.materialize(4096, -8192, build)
            second = cache.materialize(4096, -8192, build)

            self.assertEqual(first.outcome, "built")
            self.assertEqual(second.outcome, "race_hit")
            self.assertEqual(first.section, payload)
            self.assertEqual(second.stats, first.stats)
            self.assertEqual(calls, 1)
            manifests = list(cache.namespace.glob("blocks/*.json"))
            sections = list(cache.namespace.glob("sections/*.bin"))
            self.assertEqual(len(manifests), 1)
            self.assertEqual(len(sections), 1)
            manifest = json.loads(manifests[0].read_bytes())
            self.assertEqual(manifest["block"]["boundsMeters"], [4096, -8192, 8192, -4096])
            self.assertEqual(manifest["section"]["sha256"], hashlib.sha256(payload).hexdigest())

    def test_corrupt_section_is_never_returned_and_is_rebuilt(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = BuildingBlockCache(tmp, identity())
            first_payload = b"first-section"
            first = cache.materialize(
                0,
                0,
                lambda: (first_payload, stats(section_bytes=len(first_payload))),
            )
            section_path = next(cache.namespace.glob("sections/*.bin"))
            section_path.write_bytes(b"corrupt")

            self.assertIsNone(cache.load(0, 0))
            second_payload = b"second-section"
            second = cache.materialize(
                0,
                0,
                lambda: (second_payload, stats(section_bytes=len(second_payload))),
            )

            self.assertEqual(first.outcome, "built")
            self.assertEqual(second.outcome, "built")
            self.assertEqual(second.section, second_payload)

    def test_overlapping_writers_compute_a_block_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = BuildingBlockCache(tmp, identity())
            barrier = threading.Barrier(3)
            calls = 0
            calls_lock = threading.Lock()
            results = []
            payload = b"shared-section"

            def build():
                nonlocal calls
                with calls_lock:
                    calls += 1
                time.sleep(0.05)
                return payload, stats(section_bytes=len(payload))

            def run():
                barrier.wait()
                results.append(cache.materialize(0, 0, build))

            threads = [threading.Thread(target=run) for _ in range(2)]
            for thread in threads:
                thread.start()
            barrier.wait()
            for thread in threads:
                thread.join(timeout=2)

            self.assertEqual(calls, 1)
            self.assertEqual(sorted(result.outcome for result in results), ["built", "race_hit"])
            self.assertTrue(all(result.section == payload for result in results))

    def test_rejects_unaligned_coordinates_and_invalid_stats(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = BuildingBlockCache(tmp, identity())
            with self.assertRaisesRegex(BuildingBlockCacheError, "coordinates"):
                cache.load(1, 0)
            with self.assertRaisesRegex(BuildingBlockCacheError, "statistics"):
                cache.materialize(
                    0,
                    0,
                    lambda: (b"section", {**stats(section_bytes=7), "recordCount": 2}),
                )


if __name__ == "__main__":
    unittest.main()
