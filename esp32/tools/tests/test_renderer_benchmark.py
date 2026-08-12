import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest


TOOLS = Path(__file__).parents[1]
sys.path.insert(0, str(TOOLS))
SPEC = importlib.util.spec_from_file_location(
    "renderer_benchmark", TOOLS / "renderer_benchmark.py"
)
assert SPEC and SPEC.loader
renderer_benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(renderer_benchmark)


def map_manifest() -> dict:
    return {
        "schemaVersion": 1,
        "mapId": "shanghai-renderer-v1",
        "target": {
            "renderer": "esp32-fmb",
            "formatVersion": 3,
            "labelProfileVersion": 1,
            "labelLanguages": ["zh-Hans", "en"],
            "internationalFallback": "en",
            "buildingProfileVersion": 1,
            "minFirmwareVersion": "1.2.3",
        },
        "buildings": {
            "recordCount": 6,
            "explicitHeightCount": 1,
            "levelsHeightCount": 2,
            "inheritedHeightCount": 3,
            "localMedianHeightCount": 0,
            "classDefaultHeightCount": 0,
        },
        "files": [
            {
                "path": "VECTMAP/shanghai-renderer-v1/+0000+0000/1.fmb",
                "bytes": 123,
                "sha256": "a" * 64,
            }
        ],
    }


def snapshot(
    *,
    sequence: int,
    timestamp_ms: int,
    map_fixture: dict,
    route_id: str,
    route_sha256: str,
) -> dict:
    timing = {
        "count": 30,
        "lastMs": 100,
        "p50Ms": 100,
        "p95Ms": 200,
        "maximumMs": 250,
    }
    return {
        "ok": True,
        "schema": 1,
        "sequence": sequence,
        "timestampMs": timestamp_ms,
        "window": {
            "id": 0x80000001,
            "startedAtMs": 500,
            "runId": "ble-0102030405060708",
            "repeat": 1,
        },
        "identity": {
            "deviceId": "0123456789abcdef",
            "firmwareCommit": "1" * 40,
            "board": "WAVESHARE_AMOLED_175",
            "buildProfile": "WAVESHARE_AMOLED_175",
            "bootId": 7,
            "resetReason": 1,
            "mapFixture": {
                "id": map_fixture["id"],
                "sha256": map_fixture["manifestReceipt"],
            },
            "routeFixture": {
                "id": route_id,
                "sha256": route_sha256,
                "mode": "ordinary-ble-1hz",
            },
        },
        "tuning": {
            "profile": "medium",
            "fingerprint": renderer_benchmark.expected_tuning_fingerprint(
                "medium"
            ),
            "minimumExtrusionAreaPx2": 6,
            "total": {
                "records": 96,
                "points": 8192,
                "projectedPixels": 220000,
            },
            "extrusion": {
                "records": 40,
                "points": 3840,
                "projectedPixels": 112500,
            },
        },
        "memory": {
            "internalHeap": {
                "free": 50_000,
                "minimumEverFree": 45_000,
                "largestBlock": 30_000,
                "windowMinimumFree": 45_000,
                "windowMinimumLargestBlock": 25_000,
            },
            "psram": {
                "free": 2_500_000,
                "largestBlock": 1_500_000,
                "windowMinimumFree": 2_400_000,
                "windowMinimumLargestBlock": 1_400_000,
            },
        },
        "render": {
            "timings": {
                "total": timing,
                "blockLoad": timing,
                "draw": timing,
                "buildingProjection": timing,
                "buildingDraw": timing,
                "buildingTotal": timing,
            },
            "buildings": {
                "candidates": 70,
                "selected": 60,
                "extruded": 40,
                "flat": 20,
                "deferred": 10,
                "oversized": 0,
                "rendered": 60,
                "allocationFallback": False,
                "extrudedP90DistancePx": 80,
                "extrudedFarthestDistancePx": 100,
                "limiterFlags": 0,
                "limiterPasses": {
                    "records": 0,
                    "points": 0,
                    "projectedPixels": 0,
                    "extrudedRecords": 0,
                    "extrudedPoints": 0,
                    "extrudedPixels": 0,
                },
            },
            "jobs": {
                "requested": 30,
                "started": 30,
                "completed": 30,
                "published": 30,
                "stale": 0,
                "cancelled": 0,
                "interrupted": 0,
                "coverageRejected": 0,
                "invariantFailed": 0,
            },
        },
        "ui": {"maximumGapMs": 100},
        "displayFlush": {
            "count": 30,
            "lastMs": 80,
            "p50Ms": 80,
            "p95Ms": 100,
            "maximumMs": 120,
        },
        "gps": {
            "packets": timestamp_ms // 1000,
            "latestPacketGapMs": 1000,
            "maximumPacketGapMs": 1000,
            "predictionGraceEntries": 10,
            "predictionExhaustionEntries": 0,
        },
        "routeReplay": {
            "valid": True,
            "fixtureSha256": route_sha256,
            "fixtureMatches": True,
            "sampleIndex": sequence % 120,
            "sampleCount": 120,
            "loop": 0,
            "receivedAtMs": timestamp_ms,
            "accepted": timestamp_ms // 1000,
            "rejected": 0,
        },
        "remoteDebug": {
            "active": False,
            "snapshotBytes": 0,
            "captured": 0,
            "skippedCadence": 0,
            "skippedLocked": 0,
            "captureErrors": 0,
            "lastCopyUs": 0,
            "maximumCopyUs": 0,
            "lastHttpResponseMs": 0,
            "maximumHttpResponseMs": 0,
            "freeBefore": 0,
            "largestBefore": 0,
            "freeAfterAllocate": 0,
            "largestAfterAllocate": 0,
        },
    }


class RendererBenchmarkTests(unittest.TestCase):
    def test_balanced_schedule_rotates_first_order(self):
        self.assertEqual(
            renderer_benchmark.balanced_profile_schedule(3),
            [
                ["flat", "current", "high", "medium"],
                ["current", "medium", "flat", "high"],
                ["medium", "high", "current", "flat"],
            ],
        )

    def test_map_fixture_receipt_matches_firmware_canonical_shape(self):
        manifest = map_manifest()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            fixture = renderer_benchmark.load_map_fixture(path)
        canonical = (
            "1\nshanghai-renderer-v1\nesp32-fmb\n3\n1\n"
            "zh-Hans\nen\nen\n1\n6\n1\n2\n3\n0\n0\n1.2.3\n"
            "VECTMAP/shanghai-renderer-v1/+0000+0000/1.fmb\n"
            "VECTMAP/+0000+0000/1.fmb\n123\n"
            + "a" * 64
            + "\n"
        ).encode()
        self.assertEqual(
            fixture["manifestReceipt"], hashlib.sha256(canonical).hexdigest()
        )
        self.assertEqual(fixture["id"], "shanghai-renderer-v1")

    def test_signed_map_stream_uses_exact_embedded_manifest_receipt(self):
        manifest = map_manifest()
        manifest_bytes = json.dumps(
            manifest, sort_keys=True, separators=(",", ":")
        ).encode()
        key_id = b"test-key"
        envelope = struct.pack("<BBH", 1, len(key_id), 64) + key_id + b"s" * 64
        payload = b"p" * 123
        header = struct.pack(
            "<8sHHIHHIQ",
            b"BIKEMAP1",
            1,
            0,
            len(manifest_bytes),
            len(envelope),
            0,
            1,
            len(payload),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "shanghai.bmap"
            path.write_bytes(header + manifest_bytes + envelope + payload)
            fixture = renderer_benchmark.load_map_fixture(path)
        self.assertEqual(fixture["sourceType"], "bike-map-stream-v1")
        self.assertEqual(
            fixture["manifestReceipt"], hashlib.sha256(manifest_bytes).hexdigest()
        )
        self.assertEqual(
            fixture["signedManifestReceipt"],
            hashlib.sha256(
                b"open-bike-computer-map-manifest-v1\0"
                + manifest_bytes
                + envelope
            ).hexdigest(),
        )

    def test_monotonic_decline_detects_leak_shape_not_stable_noise(self):
        self.assertTrue(
            renderer_benchmark.monotonic_decline(
                [100_000 - index * 500 for index in range(25)],
                minimum_samples=20,
                allowed_decline=4096,
            )
        )
        self.assertFalse(
            renderer_benchmark.monotonic_decline(
                [100_000 + (index % 3) * 100 for index in range(25)],
                minimum_samples=20,
                allowed_decline=4096,
            )
        )

    def test_pareto_candidate_excludes_absolute_failures(self):
        base = {
            "passed": True,
            "renderP95Ms": 200,
            "buildingP95Ms": 100,
            "uiMaximumGapMs": 200,
            "minimumInternalFree": 50_000,
            "minimumPsramFree": 2_500_000,
            "extrudedBuildings": 32,
            "extrudedP90DistancePx": 60,
            "extrudedFarthestDistancePx": 80,
            "flatBuildings": 30,
            "deferredBuildings": 20,
        }
        medium = {
            **base,
            "extrudedBuildings": 40,
            "extrudedP90DistancePx": 80,
            "extrudedFarthestDistancePx": 100,
            "flatBuildings": 20,
            "deferredBuildings": 10,
        }
        high = {**medium, "passed": False}
        result = renderer_benchmark.choose_pareto_candidate(
            {"current": base, "medium": medium, "high": high},
            renderer_benchmark.load_gates(
                TOOLS / "renderer_benchmark_gates.json"
            ),
        )
        self.assertEqual(result["selected"], "medium")
        self.assertIn("high", result["exclusions"])

    def test_route_marker_age_and_stall_are_hard_failures(self):
        fixture = {
            "id": "shanghai-renderer-v1",
            "manifestReceipt": "a" * 64,
        }
        route_hash = "b" * 64
        snapshots = [
            snapshot(
                sequence=index + 1,
                timestamp_ms=1000 + index * 5000,
                map_fixture=fixture,
                route_id="shanghai-center-renderer-v1",
                route_sha256=route_hash,
            )
            for index in range(13)
        ]
        for value in snapshots:
            value["routeReplay"]["receivedAtMs"] = 1000
            value["routeReplay"]["sampleIndex"] = 7
            value["gps"]["packets"] = 0
        samples = [
            renderer_benchmark.compact_sample(value, index * 5)
            for index, value in enumerate(snapshots)
        ]
        failures = renderer_benchmark.evaluate_run(
            snapshots=snapshots,
            samples=samples,
            summary=renderer_benchmark.summarize_run(snapshots, samples),
            duration_seconds=60,
            poll_interval_seconds=5,
            screenshots=[],
            checkpoint_count=0,
            expected_route_sample_count=120,
            gates=renderer_benchmark.load_gates(
                TOOLS / "renderer_benchmark_gates.json"
            ),
            expect_remote_debug=False,
        )
        self.assertIn("stale_route_marker", failures)
        self.assertIn("stalled_route_marker", failures)
        self.assertIn("missing_gps_packets", failures)

    def test_ordinary_capture_is_bound_to_remote_winner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            map_path = root / "manifest.json"
            map_path.write_text(json.dumps(map_manifest()), encoding="utf-8")
            fixture = renderer_benchmark.load_map_fixture(map_path)
            route_path = renderer_benchmark.DEFAULT_ROUTE_FIXTURE
            route = renderer_benchmark.validate_route_fixture(route_path)
            route_hash = renderer_benchmark.sha256_file(route_path)
            snapshots = [
                snapshot(
                    sequence=index + 1,
                    timestamp_ms=1000 + index * 5000,
                    map_fixture=fixture,
                    route_id=route["id"],
                    route_sha256=route_hash,
                )
                for index in range(13)
            ]
            capture_path = root / "capture.json"
            capture_path.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "kind": "ordinary-renderer-diagnostics",
                        "routeFixture": {
                            "id": route["id"],
                            "sha256": route_hash,
                            "mode": "ordinary-ble-1hz",
                        },
                        "snapshots": snapshots,
                    }
                ),
                encoding="utf-8",
            )
            comparison_path = root / "renderer-benchmark.json"
            comparison_path.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "passed": True,
                        "identity": {
                            "deviceId": "0123456789abcdef",
                            "firmwareCommit": "1" * 40,
                            "board": "WAVESHARE_AMOLED_175",
                        },
                        "pareto": {"selected": "medium"},
                        "fixtures": {
                            "map": fixture,
                            "route": {
                                "id": route["id"],
                                "sha256": route_hash,
                            },
                        },
                    }
                ),
                encoding="utf-8",
            )
            report = renderer_benchmark.evaluate_ordinary_capture(
                capture_path=capture_path,
                comparison_path=comparison_path,
                map_fixture=fixture,
                route_fixture=route,
                route_fixture_sha256=route_hash,
                gates=renderer_benchmark.load_gates(
                    TOOLS / "renderer_benchmark_gates.json"
                ),
                allow_partial=False,
            )
        self.assertTrue(report["passed"], report["failures"])
        self.assertEqual(report["window"]["profile"], "medium")


if __name__ == "__main__":
    unittest.main()
