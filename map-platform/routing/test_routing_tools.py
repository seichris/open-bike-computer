import hashlib
import io
import json
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from shapely.geometry import Point, box, mapping

from build_graph import (
    ARCHIVE_NAME, INDEX_ENTRY, archive_tile_count, argument_error, elevation_identity, file_identity,
    prepare_inputs, valhalla_build,
)
from coverage_mask import DISPUTES, MAP_UNITS, build_mask, check_apple_list, mask_feature
from stage_graph import stage
import build_elevation
import probe_graph
import probe_profiles


def write_archive(path, offset=1536):
    tile_name = "2/000/145.gph"
    with tarfile.open(path, "w") as stream:
        for name, data in [("index.bin", INDEX_ENTRY.pack(offset, (145 << 3) | 2, 3)), (tile_name, b"abc")]:
            member = tarfile.TarInfo(name)
            member.size = len(data)
            stream.addfile(member, io.BytesIO(data))


class CoverageTests(unittest.TestCase):
    def test_apple_list_rejects_changed_and_duplicate_entries(self):
        prefix = '<section id="maps-cycling"><ul>'
        suffix = '</ul></section><section><ul><li>Other</li></ul></section>'
        check_apple_list(prefix + "<li>France</li>" + suffix, {"France"})
        with self.assertRaises(ValueError):
            check_apple_list(prefix + "<li>France</li><li>France</li>" + suffix, {"France"})
        with self.assertRaises(ValueError):
            check_apple_list(prefix + "<li>Japan</li>" + suffix, {"France"})

    def test_mask_retains_border_dispute_and_unlisted_overlap(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            layers = {
                MAP_UNITS: [("FXX", box(0, 0, 4, 4)), ("ZZZ", box(2, 1, 3, 2))],
                DISPUTES: [("DIS", box(1, 1, 1.5, 2))],
            }
            checksums = {}
            for filename, layer in layers.items():
                data = json.dumps({"features": [
                    {"properties": {"GU_A3": code}, "geometry": mapping(geometry)}
                    for code, geometry in layer
                ]}).encode()
                (directory / filename).write_bytes(data)
                checksums[filename] = hashlib.sha256(data).hexdigest()
            mask, inventory = build_mask({
                "schema": "bicino-bicycle-coverage-v1",
                "boundaryFiles": checksums,
                "borderBufferMeters": 30000,
                "appleCyclingMapUnits": {"France": ["FXX"]},
            }, directory)
            self.assertTrue(mask.covers(Point(0.2, 2)))
            self.assertTrue(mask.covers(Point(1.25, 1.5)))
            self.assertTrue(mask.covers(Point(2.5, 1.5)))
            self.assertFalse(mask.covers(Point(0.6, 2)))
            self.assertFalse(inventory["ZZZ"]["excludedArea"])

    @unittest.skipUnless(shutil.which("osmium"), "Osmium CLI is required")
    def test_extract_retains_ferry_member_outside_mask(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            source = directory / "input.osm"
            source.write_text(
                '<osm version="0.6"><node id="1" lat="0.1" lon="0.1"/>'
                '<node id="2" lat="0.2" lon="0.2"/><node id="3" lat="2" lon="2"/>'
                '<node id="4" lat="2.1" lon="2.1"/><way id="10"><nd ref="1"/><nd ref="2"/></way>'
                '<way id="11"><nd ref="3"/><nd ref="4"/></way><relation id="20">'
                '<member type="way" ref="10" role=""/><member type="way" ref="11" role=""/>'
                '<tag k="type" v="route"/><tag k="route" v="ferry"/></relation></osm>'
            )
            mask = directory / "mask.geojson"
            mask.write_text(json.dumps(mask_feature(box(0, 0, 1, 1))))
            _, roads = prepare_inputs(source, directory, mask)
            result = subprocess.check_output(["osmium", "cat", roads, "-f", "opl"], text=True)
            self.assertIn("w11 ", result)
            self.assertIn("r20 ", result)


class BuildArgumentTests(unittest.TestCase):
    PLANET = "https://planet.openstreetmap.org/pbf/planet-261116.osm.pbf"

    def test_worldwide_gap_needs_a_mask_and_planet_takes_none(self):
        mask = Path("mask.geojson")
        self.assertIsNone(argument_error("worldwide-gap", False, mask, self.PLANET))
        self.assertIn("require a mask", argument_error("worldwide-gap", False, None, self.PLANET))
        self.assertIsNone(argument_error("planet", False, None, self.PLANET))
        self.assertIn("take no mask", argument_error("planet", False, mask, self.PLANET))

    def test_release_builds_need_a_dated_planet_snapshot(self):
        for coverage in ("worldwide-gap", "planet"):
            mask = Path("mask.geojson") if coverage == "worldwide-gap" else None
            self.assertIn("dated", argument_error(coverage, False, mask, "https://example.com/planet-latest.osm.pbf"))
        self.assertIsNone(argument_error("planet", True, None, "file:///sample.osm.pbf"))


class ElevationTileTests(unittest.TestCase):
    def test_hgt_names_follow_the_srtm_layout(self):
        self.assertEqual(build_elevation.hgt_name(8, 47), "N47E008")
        self.assertEqual(build_elevation.hgt_name(-1, -1), "S01W001")
        self.assertEqual(build_elevation.hgt_name(-180, 0), "N00W180")
        self.assertEqual(build_elevation.hgt_path(Path("/e"), 8, 47), Path("/e/N47/N47E008.hgt.gz"))

    def test_neighbours_wrap_the_antimeridian_and_stop_at_the_poles(self):
        self.assertEqual(build_elevation.neighbour(179, 10, 1, 0), ((-180, 10), 360))
        self.assertEqual(build_elevation.neighbour(-180, 10, -1, -1), ((179, 9), -360))
        self.assertEqual(build_elevation.neighbour(5, 10, 1, 1), ((6, 11), 0))
        self.assertIsNone(build_elevation.neighbour(0, 89, 0, 1))
        self.assertIsNone(build_elevation.neighbour(0, -90, 0, -1))

    def test_higher_priority_source_wins_each_cell(self):
        class Source:
            def __init__(self, id, priority):
                self.id, self.priority = id, priority

        glo30, glo90 = Source("glo30", 100), Source("glo90", 50)
        chosen = build_elevation.choose_sources(
            [glo90, glo30], {"glo30": {(1, 1)}, "glo90": {(1, 1), (2, 2)}})
        self.assertEqual({cell: source.id for cell, source in chosen.items()}, {(1, 1): "glo30", (2, 2): "glo90"})

    def test_posts_are_rounded_big_endian_with_a_no_data_marker(self):
        import numpy as np

        heights = np.zeros((3601, 3601), dtype="float32")
        heights[0, :4] = [1.4, -1.6, 40000, np.nan]
        payload, missing = build_elevation.encode_posts(heights)
        self.assertEqual(len(payload), 3601 * 3601 * 2)
        self.assertEqual(missing, 1)
        self.assertEqual(np.frombuffer(payload[:8], dtype=">i2").tolist(), [1, -2, 32767, -32768])
        with self.assertRaises(ValueError):
            build_elevation.encode_posts(np.zeros((1201, 1201), dtype="float32"))

    def test_border_posts_come_from_the_neighbour(self):
        import numpy as np
        from affine import Affine

        step = build_elevation.STEP
        posts = Affine(step, 0, -step / 2, 0, -step, 4 * step + step / 2)
        heights = np.full((5, 5), np.nan, dtype="float32")
        own = np.arange(16, dtype="float32").reshape(4, 4)
        east = np.full((5, 2), 100, dtype="float32")
        build_elevation.resample_into(heights, posts, east, posts @ Affine.translation(4, 0), 0)
        build_elevation.resample_into(heights, posts, own, posts, 0)
        np.testing.assert_array_equal(heights[:4, :4], own)
        np.testing.assert_array_equal(heights[:, 4], [100] * 5)
        self.assertTrue(np.isnan(heights[4, :4]).all())

    def test_wrapped_neighbour_is_shifted_next_to_the_cell(self):
        import numpy as np
        from affine import Affine

        step = build_elevation.STEP
        posts = Affine(step, 0, 180 - 4 * step - step / 2, 0, -step, step / 2)
        heights = np.full((1, 5), np.nan, dtype="float32")
        west_of_antimeridian = Affine(step, 0, -180 - step / 2, 0, -step, step / 2)
        build_elevation.resample_into(heights, posts, np.full((1, 2), 7, dtype="float32"),
                                      west_of_antimeridian, 360)
        self.assertEqual(heights[0, 4], 7)
        self.assertTrue(np.isnan(heights[0, :4]).all())

    def test_only_neighbours_holding_border_posts_are_read(self):
        import numpy as np
        from affine import Affine
        from rasterio.io import MemoryFile

        step = 10 / 3600

        def point_registered(longitude, latitude):
            memory = MemoryFile()
            transform = Affine(step, 0, longitude - step / 2, 0, -step, latitude + 1 + step / 2)
            with memory.open(driver="GTiff", width=360, height=360, count=1, dtype="float32",
                             crs="EPSG:4326", transform=transform) as dataset:
                dataset.write(np.full((1, 360, 360), 5, dtype="float32"))
                dataset.update_tags(AREA_OR_POINT="Point")
            return memory

        for (longitude, latitude), shift, expected in (
            ((9, 47), 0, True),      # east of cell (8, 47)
            ((8, 46), 0, True),      # south
            ((9, 46), 0, True),      # south-east
            ((7, 47), 0, False),     # west
            ((8, 48), 0, False),     # north
            ((-180, 47), 360, True), # east across the antimeridian of cell (179, 47)
        ):
            cell_longitude = 8 if shift == 0 else 179
            with self.subTest(neighbour=(longitude, latitude)), point_registered(longitude, latitude) as memory, \
                    memory.open() as dataset:
                array, _ = build_elevation.edge_window(dataset, cell_longitude, 47, (longitude, latitude), shift)
                self.assertEqual(array is not None, expected)
                if expected:
                    self.assertLessEqual(array.size, 3 * 360)


class ElevationReceiptTests(unittest.TestCase):
    class Source:
        def __init__(self, id):
            self.id = id

        def tile_url(self, longitude, latitude):
            return f"https://{self.id}/{longitude}/{latitude}.tif"

    def test_resume_rebuilds_cells_whose_source_changed(self):
        glo30, glo90 = self.Source("glo30"), self.Source("glo90")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out / "receipts").mkdir()
            receipt = {"source": "glo90", "url": glo90.tile_url(8, 47)}
            (out / "receipts" / "N47E008.json").write_text(json.dumps(receipt))
            self.assertEqual(build_elevation.current_receipt(out, (8, 47), {(8, 47): glo90}), receipt)
            self.assertIsNone(build_elevation.current_receipt(out, (8, 47), {(8, 47): glo30}))
            self.assertIsNone(build_elevation.current_receipt(out, (9, 47), {(9, 47): glo30}))

    def test_manifest_counts_sources_from_receipts_and_marks_partial_runs(self):
        class Policy:
            version = 2
            sources = [type("S", (), {"id": "glo30", "index_sha256": "i", "terms_url": "t", "attribution_url": "a"}),
                       type("S", (), {"id": "glo90", "index_sha256": "j", "terms_url": "t", "attribution_url": "a"})]

        glo30, glo90 = self.Source("glo30"), self.Source("glo90")
        chosen = {(8, 47): glo30, (9, 47): glo90, (10, 47): glo30}
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out / "receipts").mkdir()
            policy_path = out / "policy.json"
            policy_path.write_text("{}")
            for cell, source in list(chosen.items())[:2]:
                name = build_elevation.hgt_name(*cell)
                (out / "receipts" / f"{name}.json").write_text(json.dumps({
                    "cell": name, "source": source.id, "url": source.tile_url(*cell), "hgtSha256": name,
                    "bytes": 1, "fileBytes": 1, "noDataPosts": 0}))
            path = build_elevation.write_manifest(out, policy_path, Policy, chosen, [(8, 47), (9, 47)], [8, 47, 10, 48])
            manifest = json.loads(path.read_text())
            self.assertEqual((manifest["bounds"], manifest["catalogCells"], manifest["cells"]), ([8, 47, 10, 48], 3, 2))
            self.assertEqual([s["cells"] for s in manifest["sources"]], [1, 1])
            with self.assertRaises(ValueError):
                build_elevation.write_manifest(out, policy_path, Policy, chosen, list(chosen))


    def test_cells_a_dead_worker_left_behind_are_built_again(self):
        cells = [(8, 47), (9, 47), (10, 47)]
        built, calls = set(), []

        def run_pool(pending, chosen, out, jobs):
            calls.append(list(pending))
            built.add(pending[0])
            if len(calls) == 1:
                raise build_elevation.BrokenProcessPool("worker ended")
            built.update(pending)

        receipt = lambda out, cell, chosen: {} if cell in built else None
        with patch.object(build_elevation, "run_pool", run_pool), \
                patch.object(build_elevation, "current_receipt", receipt), \
                patch("builtins.print"):
            build_elevation.build_pending(cells, {}, Path("."), 2)
            self.assertEqual(calls, [cells, cells[1:]])
            built.clear(), calls.clear()
            with self.assertRaises(build_elevation.BrokenProcessPool):
                build_elevation.build_pending(cells, {}, Path("."), 2, rounds=1)

    def test_each_cell_runs_under_a_deadline(self):
        alarms = []
        with patch.object(build_elevation.signal, "alarm", alarms.append), \
                patch.object(build_elevation, "build_cell", side_effect=OSError("offline")), \
                patch.dict(build_elevation._WORKER, chosen={}, out=Path(".")):
            with self.assertRaises(OSError):
                build_elevation._build((8, 47))
        self.assertEqual(alarms, [build_elevation.CELL_DEADLINE, 0])

class ElevationManifestTests(unittest.TestCase):
    def test_graph_manifest_records_the_elevation_tiles_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            elevation = Path(tmp)
            manifest = {
                "schema": "bicino-valhalla-elevation-v1", "bounds": None, "catalogCells": 2, "cells": 2,
                "cellListSha256": "ab", "sources": [{"id": "glo30", "cells": 2}, {"id": "glo90", "cells": 0}],
            }
            (elevation / "elevation-manifest.json").write_text(json.dumps(manifest))
            identity = elevation_identity(elevation)
            self.assertEqual((identity["cells"], identity["cellListSha256"], identity["sources"]), (2, "ab", ["glo30"]))
            for partial in ({"bounds": [9, 46, 11, 48]}, {"catalogCells": 3}, {"catalogCells": None}):
                (elevation / "elevation-manifest.json").write_text(json.dumps({**manifest, **partial}))
                with self.subTest(partial=partial), self.assertRaisesRegex(ValueError, "part of the source"):
                    elevation_identity(elevation)
            (elevation / "elevation-manifest.json").write_text(json.dumps({**manifest, "bounds": [9, 46, 11, 48]}))
            self.assertEqual(elevation_identity(elevation, sample=True)["cells"], 2)
            (elevation / "elevation-manifest.json").write_text(json.dumps({"schema": "other", "cells": 2}))
            with self.assertRaises(ValueError):
                elevation_identity(elevation)

    def test_build_fails_when_valhalla_skips_the_elevation_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            skipped = "[WARN] Elevation storage directory does not exist\n"
            with patch("build_graph.run_valhalla", return_value=(work / "valhalla-build.log", skipped)):
                with self.assertRaisesRegex(ValueError, "elevation tiles"):
                    valhalla_build(work, Path("admin.osm.pbf"), Path("roads.osm.pbf"), 4, work)


class ProbeExpectationTests(unittest.TestCase):
    LEGS = [{"shape": "abc"}]

    def test_planet_override_and_coverage_filter(self):
        fairview = {"name": "Fairview", "route": False, "planet": True}
        self.assertFalse(probe_graph.expects_route(fairview, "worldwide-gap"))
        self.assertTrue(probe_graph.expects_route(fairview, "planet"))
        city = {"name": "Amsterdam", "route": True, "coverages": ["planet"]}
        self.assertFalse(probe_graph.applies(city, "worldwide-gap"))
        self.assertTrue(probe_graph.applies(city, "planet"))
        self.assertTrue(probe_graph.applies(fairview, "worldwide-gap"))

    def test_push_segments_pass_only_where_allowed(self):
        strict = {"name": "Dubai", "route": True}
        push = {"name": "Paris", "route": True, "pushAllowed": True}
        both = ["bicycle", "pedestrian"]
        self.assertTrue(probe_graph.passed(strict, "planet", self.LEGS, ["bicycle"], 1.2, None))
        self.assertFalse(probe_graph.passed(strict, "planet", self.LEGS, both, 1.2, None))
        self.assertTrue(probe_graph.passed(push, "planet", self.LEGS, both, 1.2, None))
        self.assertFalse(probe_graph.passed(push, "planet", self.LEGS, ["pedestrian"], 1.2, None))
        self.assertFalse(probe_graph.passed(push, "planet", self.LEGS, ["bicycle", "auto"], 1.2, None))
        self.assertTrue(probe_graph.passed(push, "planet", self.LEGS, both, 1.2, None, 100))
        walk = {"travel_mode": "pedestrian", "length": 0.06}
        ride = {"travel_mode": "bicycle", "length": 1.0}
        self.assertAlmostEqual(probe_graph.longest_push_meters([ride, walk, ride, walk, ride]), 60)
        self.assertAlmostEqual(probe_graph.longest_push_meters([ride, walk, walk, ride]), 120)
        self.assertFalse(probe_graph.passed(push, "planet", self.LEGS, both, 3.0, None, 101),
                         "a mostly walking route is not a bike route")

    def test_expected_misses_need_a_no_route_code(self):
        miss = {"name": "Great Bear Lake", "route": False}
        self.assertTrue(probe_graph.passed(miss, "planet", [], [], 0, 442))
        self.assertFalse(probe_graph.passed(miss, "planet", [], [], 0, 154))

    def test_checked_in_probes_are_well_formed(self):
        fixtures = json.loads(Path(probe_graph.__file__).with_name("probes.json").read_text())
        for fixture in fixtures:
            self.assertEqual(set(fixture) - {"name", "points", "route", "planet", "coverages", "pushAllowed"}, set())
            self.assertEqual(len(fixture["points"]), 2)
            self.assertTrue(set(fixture.get("coverages", probe_graph.COVERAGES)) <= set(probe_graph.COVERAGES))
        planet = [f for f in fixtures if probe_graph.applies(f, "planet") and probe_graph.expects_route(f, "planet")]
        self.assertGreaterEqual(len(planet), 15, "a planet graph must route in Apple-covered cities too")


class ArchiveTests(unittest.TestCase):
    def test_index_matches_tile_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / ARCHIVE_NAME
            write_archive(archive)
            self.assertEqual(archive_tile_count(archive), 1)
            write_archive(archive, offset=1024)
            with self.assertRaisesRegex(ValueError, "Invalid Valhalla index"):
                archive_tile_count(archive)

    def test_bad_staging_transfer_cannot_become_active(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            source = directory / "source.tar"
            write_archive(source)
            expected = {**file_identity(source), "tiles": 1}
            root = directory / "graphs"
            with patch("stage_graph.subprocess.run", side_effect=lambda args, **kw: Path(args[-1]).write_bytes(b"bad")):
                with self.assertRaisesRegex(ValueError, "SHA-256"):
                    stage(root, {"archive": expected}, str(source), 0, 20_480)
            self.assertFalse((root / expected["sha256"]).exists())
            with patch(
                "stage_graph.subprocess.run",
                side_effect=lambda args, **kw: shutil.copyfile(source, args[-1]),
            ) as transfer:
                receipt = stage(root, {"archive": expected}, str(source), 0, 20_480, compress_transfer=True)
            self.assertIn("--compress-choice=zstd", transfer.call_args.args[0])
            self.assertEqual(file_identity(receipt / ARCHIVE_NAME), file_identity(source))

    def test_already_transferred_archive_is_verified_without_retransferring(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / ARCHIVE_NAME
            write_archive(source)
            expected = {**file_identity(source), "tiles": 1}
            incoming = root / f".{expected['sha256']}.incoming"
            incoming.mkdir()
            incoming_archive = incoming / ARCHIVE_NAME
            incoming_archive.write_bytes(b"incorrectly assembled")
            with patch("stage_graph.subprocess.run") as transfer:
                with self.assertRaisesRegex(ValueError, "SHA-256"):
                    stage(root, {"archive": expected}, None, 0, 20_480)
                self.assertEqual(incoming_archive.read_bytes(), b"incorrectly assembled")
                shutil.copyfile(source, incoming_archive)
                receipt = stage(root, {"archive": expected}, None, 0, 20_480)
            transfer.assert_not_called()
            self.assertEqual(receipt, root / expected["sha256"])
            self.assertEqual(file_identity(receipt / ARCHIVE_NAME), file_identity(source))


def encode_polyline6(points):
    def encode(value):
        value = ~(value << 1) if value < 0 else value << 1
        chunks = ""
        while value >= 0x20:
            chunks += chr((0x20 | (value & 0x1F)) + 63)
            value >>= 5
        return chunks + chr(value + 63)

    encoded, previous = "", (0, 0)
    for latitude, longitude in points:
        encoded += encode(latitude - previous[0]) + encode(longitude - previous[1])
        previous = (latitude, longitude)
    return encoded


class FakeValhalla:
    """Answers like Valhalla: travel_type reports the requested bicycle type."""

    def __init__(self, *, ignore_type=False, same_geometry=False, push=0.0):
        self.ignore_type, self.same_geometry, self.push = ignore_type, same_geometry, push

    def request(self, *, method, url, headers, body, timeout_seconds, maximum_body_bytes):
        from map_platform.route_elevation_providers import ProviderHTTPResponse

        request = json.loads(body)
        bicycle_type = request["costing_options"]["bicycle"]["bicycle_type"]
        points = [(25_206_600, 55_269_200), (25_225_800, 55_263_100)]
        if bicycle_type == "road" and not self.same_geometry:
            points.insert(1, (25_216_000, 55_270_000))
        maneuvers = [{
            "type": 1, "instruction": "Ride.", "begin_shape_index": 0, "end_shape_index": len(points) - 1,
            "length": 3.0, "time": 600, "travel_mode": "bicycle",
            "travel_type": "hybrid" if self.ignore_type else bicycle_type,
        }]
        if self.push:
            maneuvers[0]["end_shape_index"] = len(points) - 2
            maneuvers.append({"type": 8, "instruction": "Walk.", "begin_shape_index": len(points) - 2,
                              "end_shape_index": len(points) - 1, "length": self.push, "time": 15,
                              "travel_mode": "pedestrian", "travel_type": "foot"})
        trip = {"status": 0, "summary": {"length": 3.0, "time": 600},
                "legs": [{"shape": encode_polyline6(points), "maneuvers": maneuvers}]}
        return ProviderHTTPResponse(200, {}, json.dumps({"trip": trip}).encode(), url)


class ProfileProbeTests(unittest.TestCase):
    FIXTURES = [{"name": "Dubai", "origin": [25.2066, 55.2692], "destination": [25.2258, 55.2631], "ready": True}]

    def run_probe(self, **fake):
        return probe_profiles.run("http://valhalla:8002", self.FIXTURES, transport_factory=lambda: FakeValhalla(**fake))

    def test_applied_types_and_differing_geometry_pass(self):
        report, failures = self.run_probe()
        self.assertEqual(failures, [])
        probe = report["probes"][0]
        self.assertTrue(probe["roadGravelGeometryDiffers"])
        self.assertEqual({name: item["bicycleTypes"] for name, item in probe["profiles"].items()},
                         {"road": ["road"], "gravel": ["cross"], "everyday": ["hybrid"],
                          "mountain": ["mountain"]})

    def test_a_silently_ignored_bicycle_type_fails(self):
        _, failures = self.run_probe(ignore_type=True)
        self.assertTrue(any("road ran as ['hybrid']" in failure for failure in failures), failures)

    def test_identical_road_and_gravel_geometry_everywhere_fails(self):
        _, failures = self.run_probe(same_geometry=True)
        self.assertIn("no pair produced different road and gravel geometry", failures)

    def test_short_push_segments_are_reported_and_stay_ready(self):
        report, failures = self.run_probe(push=0.02)
        road = report["probes"][0]["profiles"]["road"]
        self.assertEqual(road["status"], "ready")
        self.assertEqual((road["nonBicycleManeuvers"], road["nonBicycleMeters"]), (1, 20))
        self.assertEqual(failures, [])

    def test_long_push_segments_fail_a_ready_pair(self):
        report, failures = self.run_probe(push=0.15)
        road = report["probes"][0]["profiles"]["road"]
        self.assertEqual((road["status"], road["reason"]), ("unavailable", "no_bicycle_route"))
        self.assertEqual((road["nonBicycleManeuvers"], road["nonBicycleMeters"]), (1, 150))
        self.assertIn("Dubai: road was no_bicycle_route", failures)

    def test_checked_in_pairs_are_well_formed(self):
        fixtures = json.loads(Path(probe_profiles.__file__).with_name("profile-probes.json").read_text())
        self.assertGreaterEqual(len(fixtures), 2)
        for fixture in fixtures:
            self.assertEqual(set(fixture) - {"name", "origin", "destination", "ready"}, set())
            self.assertEqual(len(fixture["origin"]), 2)
            self.assertEqual(len(fixture["destination"]), 2)


if __name__ == "__main__":
    unittest.main()
