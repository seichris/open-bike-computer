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

from build_graph import ARCHIVE_NAME, INDEX_ENTRY, archive_tile_count, argument_error, file_identity, prepare_inputs
from coverage_mask import DISPUTES, MAP_UNITS, build_mask, check_apple_list, mask_feature
from stage_graph import stage
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
        self.assertFalse(probe_graph.passed(push, "planet", self.LEGS, both, 3.0, None, 2000),
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
                         {"road": ["road"], "gravel": ["cross"], "everyday": ["hybrid"]})

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
