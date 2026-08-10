import hashlib
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from building_calibration_cache import (  # noqa: E402
    CalibrationCache,
    CalibrationCacheError,
    CalibrationIdentity,
    CalibrationSample,
)
from building_pipeline import load_rules, prepare_buildings  # noqa: E402
from build_building_calibration import (  # noqa: E402
    scan_full_pbf,
    scan_pbf,
    source_cell_domain,
)
from shapely.geometry import box  # noqa: E402


def identity(**overrides):
    values = {
        "source_snapshot_sha256": "1" * 64,
        "rules_sha256": "2" * 64,
        "building_profile_version": 1,
        "cell_size_meters": 8192,
        "halo_cells": 1,
        "minimum_samples": 3,
    }
    values.update(overrides)
    return CalibrationIdentity(**values)


class CalibrationCacheTests(unittest.TestCase):
    def test_shuffled_samples_produce_identical_entries_and_median(self):
        samples = [
            CalibrationSample("w1", "office", 100),
            CalibrationSample("w2", "office", 200),
            CalibrationSample("w3", "office", 300),
        ]
        with tempfile.TemporaryDirectory() as first_root, tempfile.TemporaryDirectory() as second_root:
            first = CalibrationCache(first_root, identity())
            second = CalibrationCache(second_root, identity())
            cells = [(x, y) for x in range(-1, 2) for y in range(-1, 2)]
            first.materialize_cells(cells, {(0, 0): samples})
            second.materialize_cells(cells, {(0, 0): reversed(samples)})
            self.assertEqual(first.cell_path((0, 0)).read_bytes(), second.cell_path((0, 0)).read_bytes())
            self.assertEqual(first.local_median_meters((0, 0), "office"), 20.0)
            self.assertEqual(second.local_median_meters((0, 0), "office"), 20.0)

    def test_under_threshold_is_valid_and_uses_no_median(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            cells = [(x, y) for x in range(-1, 2) for y in range(-1, 2)]
            cache.materialize_cells(
                cells,
                {(0, 0): [CalibrationSample("w1", "house", 60), CalibrationSample("w2", "house", 80)]},
            )
            self.assertIsNone(cache.local_median_meters((0, 0), "house"))

    def test_every_identity_input_invalidates_the_cache_key(self):
        baseline = identity()
        variants = [
            identity(source_snapshot_sha256="3" * 64),
            identity(rules_sha256="4" * 64),
            identity(building_profile_version=2),
            identity(cell_size_meters=4096),
            identity(halo_cells=2),
            identity(minimum_samples=4),
        ]
        self.assertEqual(len({baseline.key, *(variant.key for variant in variants)}), len(variants) + 1)

    def test_full_precompute_and_lazy_mode_emit_identical_cells(self):
        samples = {(0, 0): [CalibrationSample("w1", "office", 100)]}
        cells = [(0, 0), (1, 0)]
        with tempfile.TemporaryDirectory() as full_root, tempfile.TemporaryDirectory() as lazy_root:
            full = CalibrationCache(full_root, identity())
            lazy = CalibrationCache(lazy_root, identity())
            full.materialize_cells(
                cells,
                samples,
                complete_source_snapshot=True,
                complete_domain_cells=cells,
            )
            lazy.materialize_cells(cells, samples)
            for cell in cells:
                self.assertEqual(full.cell_path(cell).read_bytes(), lazy.cell_path(cell).read_bytes())
            self.assertTrue(json.loads((full.key_root / "manifest.json").read_bytes())["completeSourceSnapshot"])
            self.assertFalse(json.loads((lazy.key_root / "manifest.json").read_bytes())["completeSourceSnapshot"])

    def test_complete_precompute_requires_the_exact_derived_domain(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            with self.assertRaisesRegex(CalibrationCacheError, "derived cell domain"):
                cache.materialize_cells([(0, 0)], {}, complete_source_snapshot=True)
            with self.assertRaisesRegex(CalibrationCacheError, "do not match"):
                cache.materialize_cells(
                    [(0, 0)],
                    {},
                    complete_source_snapshot=True,
                    complete_domain_cells=[(0, 0), (1, 0)],
                )

    def test_complete_manifest_rejects_cells_outside_its_bound_domain(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            cache.materialize_cells(
                [(0, 0)],
                {},
                complete_source_snapshot=True,
                complete_domain_cells=[(0, 0)],
            )
            with self.assertRaisesRegex(CalibrationCacheError, "outside"):
                cache.materialize_cells([(1, 0)], {})

    def test_full_and_lazy_pbf_scans_emit_identical_cells_and_edge_median(self):
        source = Path(__file__).parent / "fixtures" / "calibration_source.osm"
        rules, rules_sha = load_rules(ROOT / "conf" / "building_height_rules.yaml")
        cells = source_cell_domain(
            source, rules.cell_size_meters, rules.halo_cells
        )
        calibration_identity = identity(
            rules_sha256=rules_sha,
            cell_size_meters=rules.cell_size_meters,
            halo_cells=rules.halo_cells,
            minimum_samples=rules.minimum_samples,
        )
        with tempfile.TemporaryDirectory() as full_root, tempfile.TemporaryDirectory() as lazy_root:
            full = CalibrationCache(full_root, calibration_identity)
            lazy = CalibrationCache(lazy_root, calibration_identity)

            def scan(requested):
                samples, rejections, diagnostics = scan_pbf(
                    source, rules, set(requested)
                )
                return samples, rejections, diagnostics

            full.materialize_complete_with_snapshot_builder(
                lambda: scan_full_pbf(source, rules)
            )
            split = len(cells) // 2
            lazy.materialize_with_builder(cells[:split], scan)
            lazy.materialize_with_builder(cells[split:], scan)
            for cell in cells:
                self.assertEqual(
                    full.cell_path(cell).read_bytes(),
                    lazy.cell_path(cell).read_bytes(),
                )
            reader = CalibrationCache.from_manifest(full.key_root / "manifest.json")
            self.assertEqual(reader.local_median_meters((0, 0), "office"), 10.0)

    def test_corrupt_cell_is_quarantined_and_rebuilt(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            cache.materialize_cells([(0, 0)], {})
            cache.cell_path((0, 0)).write_text("{}")
            metrics = cache.materialize_cells([(0, 0)], {})
            self.assertEqual(metrics["rebuilt"], 1)
            cache.load_cell((0, 0))
            quarantined = list(cache.cell_path((0, 0)).parent.glob("0.json.corrupt-*"))
            self.assertEqual(len(quarantined), 1)

    def test_complete_manifest_membership_survives_single_cell_repair(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            cells = [(0, 0), (1, 0)]
            cache.materialize_cells(
                cells,
                {},
                complete_source_snapshot=True,
                complete_domain_cells=cells,
            )
            cache.cell_path((0, 0)).write_text("{}")
            cache.materialize_cells([(0, 0)], {})
            manifest = json.loads((cache.key_root / "manifest.json").read_bytes())
            self.assertTrue(manifest["completeSourceSnapshot"])
            self.assertEqual(
                [(entry["x"], entry["y"]) for entry in manifest["cells"]],
                cells,
            )
            CalibrationCache.from_manifest(cache.key_root / "manifest.json")

    def test_concurrent_materialization_is_single_flight_and_never_partial(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            samples = {(0, 0): [CalibrationSample("w1", "office", 120)]}
            errors = []

            def materialize():
                try:
                    cache.materialize_cells([(0, 0)], samples)
                except Exception as exc:  # pragma: no cover - asserted below
                    errors.append(exc)

            threads = [threading.Thread(target=materialize) for _ in range(4)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            self.assertEqual(errors, [])
            entry = json.loads(cache.cell_path((0, 0)).read_bytes())
            digest = entry.pop("entrySha256")
            encoded = json.dumps(entry, sort_keys=True, separators=(",", ":")).encode()
            self.assertEqual(hashlib.sha256(encoded).hexdigest(), digest)
            self.assertEqual(list(cache.key_root.rglob("*.tmp")), [])

    def test_persistent_cache_io_failure_is_typed_and_never_publishes_manifest(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            with patch("building_calibration_cache.os.replace", side_effect=OSError("disk")):
                with self.assertRaises(CalibrationCacheError) as raised:
                    cache.materialize_cells([(0, 0)], {})
            self.assertEqual(raised.exception.code, "building_calibration_unavailable")
            self.assertFalse((cache.key_root / "manifest.json").exists())

    def test_warm_and_concurrent_builder_are_single_flight(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            calls = []
            barrier = threading.Barrier(4)

            def builder(missing):
                calls.append(tuple(missing))
                return {(0, 0): [CalibrationSample("w1", "office", 120)]}, {}, {"built": True}

            def populate():
                barrier.wait()
                cache.materialize_with_builder([(0, 0)], builder)

            threads = [threading.Thread(target=populate) for _ in range(4)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            self.assertEqual(len(calls), 1)
            cache.materialize_with_builder([(0, 0)], builder)
            self.assertEqual(len(calls), 1)

    def test_concurrent_complete_snapshot_waiter_uses_peer_generation(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            barrier = threading.Barrier(2)
            scanner_started = threading.Event()
            release_scanner = threading.Event()
            calls = []
            results = []

            def snapshot_builder():
                calls.append(1)
                scanner_started.set()
                self.assertTrue(release_scanner.wait(timeout=2))
                return (
                    [(0, 0)],
                    {(0, 0): [CalibrationSample("w1", "office", 120)]},
                    {},
                    {"scan": "owner"},
                )

            def populate():
                barrier.wait()
                results.append(
                    cache.materialize_complete_with_snapshot_builder(
                        snapshot_builder
                    )
                )

            threads = [threading.Thread(target=populate) for _ in range(2)]
            for thread in threads:
                thread.start()
            self.assertTrue(scanner_started.wait(timeout=1))
            release_scanner.set()
            for thread in threads:
                thread.join(timeout=2)

            self.assertTrue(all(not thread.is_alive() for thread in threads))
            self.assertEqual(len(calls), 1)
            self.assertEqual(len(results), 2)
            self.assertEqual(
                sorted(result[0]["hits"] for result in results), [0, 1]
            )
            self.assertEqual(
                sorted(result[1] is None for result in results), [False, True]
            )

    def test_manifest_binds_cell_hash_and_corruption_is_quarantined(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            cache.materialize_cells([(0, 0)], {(0, 0): [CalibrationSample("w1", "office", 100)]})
            manifest = json.loads((cache.key_root / "manifest.json").read_bytes())
            self.assertEqual(manifest["cells"][0]["entrySha256"], cache.load_cell((0, 0))["entrySha256"])
            manifest["cells"].append({"x": 999, "y": 999, "entrySha256": "0" * 64})
            (cache.key_root / "manifest.json").write_text(json.dumps(manifest))
            cache.materialize_cells([(0, 0)], {})
            rebuilt = json.loads((cache.key_root / "manifest.json").read_bytes())
            self.assertEqual([(item["x"], item["y"]) for item in rebuilt["cells"]], [(0, 0)])
            self.assertEqual(len(list(cache.key_root.glob("manifest.json.corrupt-*"))), 1)

    def test_manifest_reader_never_consumes_an_unlisted_halo_cell(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            cells = [(x, y) for x in range(-1, 2) for y in range(-1, 2)]
            cache.materialize_cells(cells, {})
            manifest_path = cache.key_root / "manifest.json"
            manifest_path.write_text("{}")
            cache.materialize_cells([(0, 0)], {})
            reader = CalibrationCache.from_manifest(manifest_path)
            with self.assertRaisesRegex(CalibrationCacheError, "not bound"):
                reader.local_median_meters((0, 0), "office")

    def test_manifest_rewrite_revalidates_unrelated_cells_from_disk(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            cache.materialize_cells([(0, 0), (1, 0)], {})
            cache.load_cell((1, 0))
            cache.cell_path((1, 0)).write_text("{}")
            with self.assertRaises(CalibrationCacheError):
                cache.materialize_cells([(0, 0)], {})

    def test_loaded_cell_is_defensively_copied(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity(minimum_samples=1))
            cache.materialize_cells(
                [(0, 0)],
                {(0, 0): [CalibrationSample("w1", "office", 120)]},
            )
            loaded = cache.load_cell((0, 0))
            loaded["classes"]["office"]["heightHistogramDm"]["120"] = 99
            self.assertEqual(cache.load_cell((0, 0))["classes"]["office"]["heightHistogramDm"]["120"], 1)

    def test_cell_coordinates_cannot_escape_cache_root(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            with self.assertRaises(CalibrationCacheError):
                cache.materialize_cells([("../../outside", 0)], {})

    def test_one_osm_object_cannot_sample_multiple_classes(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            with self.assertRaisesRegex(CalibrationCacheError, "duplicated"):
                cache.materialize_cells(
                    [(0, 0)],
                    {
                        (0, 0): [
                            CalibrationSample("w1", "office", 100),
                            CalibrationSample("w1", "house", 120),
                        ]
                    },
                )

    def test_one_osm_object_cannot_appear_in_neighboring_cells(self):
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity())
            with self.assertRaisesRegex(CalibrationCacheError, "multiple cells"):
                cache.materialize_cells(
                    [(0, 0), (1, 0)],
                    {
                        (0, 0): [CalibrationSample("w1", "office", 100)],
                        (1, 0): [CalibrationSample("w1", "office", 300)],
                    },
                )

    def test_cache_reader_rejects_identity_mismatch(self):
        fixture = json.loads(
            (Path(__file__).parent / "fixtures" / "selected_area_buildings.json").read_text()
        )
        rules, rules_sha = load_rules(ROOT / "conf" / "building_height_rules.yaml")
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity(rules_sha256="9" * 64))
            with self.assertRaisesRegex(CalibrationCacheError, "does not match"):
                prepare_buildings(
                    fixture["features"],
                    rules,
                    fixture["relationIndex"],
                    calibration_cache=cache,
                    calibration_rules_sha256=rules_sha,
                    calibration_source_sha256=cache.identity.source_snapshot_sha256,
                )

    def test_overlapping_selections_resolve_identical_cache_height(self):
        fixture = json.loads(
            (Path(__file__).parent / "fixtures" / "selected_area_buildings.json").read_text()
        )
        rules, rules_sha = load_rules(ROOT / "conf" / "building_height_rules.yaml")
        with tempfile.TemporaryDirectory() as root:
            cache = CalibrationCache(root, identity(rules_sha256=rules_sha))
            cells = [(x, y) for x in range(-1, 3) for y in range(-1, 2)]
            cache.materialize_cells(
                cells,
                {
                    (0, 0): [
                        CalibrationSample("w1", "office", 240),
                        CalibrationSample("w7", "office", 100),
                    ],
                    (1, 0): [
                        CalibrationSample("w8", "office", 200),
                        CalibrationSample("w9", "office", 300),
                    ],
                },
            )
            narrow, _, _ = prepare_buildings(
                fixture["features"],
                rules,
                fixture["relationIndex"],
                selection_geometry=box(1900, 1900, 2100, 2100),
                calibration_cache=cache,
                calibration_rules_sha256=rules_sha,
                calibration_source_sha256=cache.identity.source_snapshot_sha256,
            )
            broad, _, _ = prepare_buildings(
                fixture["features"],
                rules,
                fixture["relationIndex"],
                selection_geometry=box(0, 0, 9000, 9000),
                calibration_cache=cache,
                calibration_rules_sha256=rules_sha,
                calibration_source_sha256=cache.identity.source_snapshot_sha256,
            )
            narrow_height = next(item.resolved for item in narrow if item.object_key == "w6")
            broad_height = next(item.resolved for item in broad if item.object_key == "w6")
            self.assertEqual(narrow_height, broad_height)
            self.assertEqual(narrow_height.height_dm, 220)


if __name__ == "__main__":
    unittest.main()
