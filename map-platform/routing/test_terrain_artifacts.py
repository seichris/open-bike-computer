import gzip
import http.server
import json
import math
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import build_elevation
import terrain_artifacts as ta

POSTS = build_elevation.POSTS
CELL = (-80, 43)
NAME = "N43W080"
# The planted pit, the quarries, the block of zeros and the slot, by their north-west post.
PIT = (1000, 1000)
QUARRY = (2000, 2000)
NEW_QUARRY = (2000, 1000)
ZEROS = (3000, 2500)
DROPPED = (3000, 500)
HILLS = (slice(400, 1000), slice(2400, 3000))
SLOT = (600, 2600)


def place(row, column):
    last = POSTS - 1
    return CELL[1] + 1 - row / last, CELL[0] + column / last


def encode(points):
    """Valhalla's encoded polyline, precision 6."""
    out, last = [], (0, 0)
    for lat, lon in points:
        here = (round(lat * 1e6), round(lon * 1e6))
        for value in (here[0] - last[0], here[1] - last[1]):
            value = ~(value << 1) if value < 0 else value << 1
            while value >= 0x20:
                out.append(chr((0x20 | (value & 0x1F)) + 63))
                value >>= 5
            out.append(chr(value + 63))
        last = here
    return "".join(out)


def scene():
    """Terrain, opened and hybrid posts of one cell; returns the three arrays.

    A level plain at 150 m with a slight tilt and a forest 8 m high over it in Copernicus. On it: a pit of 3 by 3
    posts 45 m deep that only the terrain has (an artifact); a quarry 20 by 28 posts and 40 m deep that Copernicus
    shows too, and one of 14 by 16 posts dug since, which it does not; a block of 14 by 14 posts of zero heights; hills
    whose basins Copernicus shows and whose highest top holds a slot of 2 by 2 posts 60 m deep that it does not;
    and a pit whose pixels the reader dropped, so that the hybrid takes Copernicus there.
    """
    import numpy as np

    rows, columns = np.mgrid[0:POSTS, 0:POSTS].astype("float32")
    terrain = (150 + 0.002 * columns).astype("float32")
    hills = terrain[HILLS] + 150 * np.sin(rows[HILLS] / 8) * np.cos(columns[HILLS] / 8)
    terrain[HILLS] = hills
    opened = terrain + 8
    r, c = PIT
    terrain[r:r + 3, c:c + 3] -= 45
    r, c = QUARRY
    terrain[r:r + 20, c:c + 28] -= 40
    opened[r:r + 20, c:c + 28] = terrain[r:r + 20, c:c + 28] + 2
    r, c = NEW_QUARRY
    terrain[r:r + 14, c:c + 16] -= 40
    r, c = ZEROS
    terrain[r:r + 14, c:c + 14] = 0
    # The slot on a hilltop: the hills peak where sin(r/8) and cos(c/8) are both 1 or both -1.
    r, c = SLOT
    peak = np.unravel_index(int(np.argmax(terrain[r - 30:r + 30, c - 30:c + 30])), (60, 60))
    slot = (r - 30 + int(peak[0]), c - 30 + int(peak[1]))
    terrain[slot[0]:slot[0] + 2, slot[1]:slot[1] + 2] -= 60
    hybrid = terrain.copy()
    r, c = DROPPED
    terrain[r:r + 3, c:c + 3] -= 45
    hybrid[r - 4:r + 7, c - 4:c + 7] = opened[r - 4:r + 7, c - 4:c + 7]
    terrain[r - 1:r + 4, c - 1:c + 4] = np.nan
    return terrain, opened, hybrid, slot


def write_set(directory, heights, receipt=None):
    (directory / "receipts").mkdir(parents=True)
    build_elevation.write_tile(directory, CELL, heights)
    if receipt is not None:
        build_elevation.write_receipt(directory, receipt)


class FakeValhalla(http.server.BaseHTTPRequestHandler):
    """/locate that answers every location with the same edges, or with an error while `broken` is set."""

    edges = []
    broken = False
    asked = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).asked.append(body)
        if self.path != "/locate" or type(self).broken:
            self.send_error(500)
            return
        answer = json.dumps([{"input_lat": location["lat"], "input_lon": location["lon"], "edges": type(self).edges}
                             for location in body["locations"]]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)

    def log_message(self, *arguments):
        pass


def edge(points, way, kind="residential", use="road", surface="paved_smooth", bridge=False, tunnel=False):
    return {"edge_info": {"shape": encode(points), "way_id": way, "names": [f"Way {way}"]},
            "edge": {"classification": {"classification": kind, "use": use, "surface": surface},
                     "bridge": bridge, "tunnel": tunnel,
                     "geo_attributes": {"weighted_grade": 9.5, "max_up_slope": 61.0, "max_down_slope": 58.0}}}


class TerrainScanTests(unittest.TestCase):
    """One cell scanned once, with the 3DEP area over its western half."""

    @classmethod
    def setUpClass(cls):
        import numpy as np

        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        cls.root = Path(directory.name)
        terrain, opened, hybrid, cls.slot = scene()
        receipt = {"cell": NAME, "sources": [{"source": "usgs-3dep-13"}, {"source": "nrcan-mrdem-30"}],
                   "rejectedPixels": 25}
        write_set(cls.root / "terrain", terrain, receipt)
        write_set(cls.root / "opened", opened)
        write_set(cls.root / "hybrid", hybrid)
        # A cell with a terrain tile and no hybrid tile, as a sample's neighbours have.
        build_elevation.write_receipt(cls.root / "terrain", {"cell": "N43W081", "sources": [{"source": "nrcan-mrdem-30"}]})
        west = np.zeros((POSTS, POSTS), dtype=bool)
        west[:, :1800] = True

        def posts_in_area(cell, area):
            return west if area == "usgs-3dep-13" else True

        def load_area(path, _sha256):
            return "usgs-3dep-13" if "united-states" in path.name else "nrcan-mrdem-30"

        with patch.object(build_elevation, "posts_in_area", posts_in_area), \
                patch.object(build_elevation, "load_area", load_area):
            cls.summary = ta.scan(cls.root / "terrain", cls.root / "opened", cls.root / "hybrid", cls.root / "out",
                                  jobs=1, say=lambda _text: None)
        cls.steep = [group for _, _, group in ta.steep_groups(cls.root / "out")]

    def row(self):
        return next(row for row in self.summary["rows"] if row["cell"] == NAME)

    def near(self, corner, rows, columns):
        return [group for group in self.steep
                if corner[0] - 2 <= (CELL[1] + 1 - group["latitude"]) * (POSTS - 1) <= corner[0] + rows + 2
                and corner[1] - 2 <= (group["longitude"] - CELL[0]) * (POSTS - 1) <= corner[1] + columns + 2]

    def test_the_planted_pit_is_an_artifact_candidate_and_carries_its_source(self):
        candidates = [group for group in self.steep if group["candidate"]]
        self.assertEqual(len(candidates), 2, candidates)
        pit, = self.near(PIT, 3, 3)
        self.assertTrue(pit["candidate"])
        latitude, longitude = place(PIT[0] + 1, PIT[1] + 1)
        self.assertAlmostEqual(pit["latitude"], latitude, delta=1.5 / 3600)
        self.assertAlmostEqual(pit["longitude"], longitude, delta=1.5 / 3600)
        self.assertEqual((pit["source"], pit["posts"]), ("usgs-3dep-13", 9))
        self.assertGreater(pit["closedDepth"], 40)
        self.assertGreater(pit["furtherUnderOpened"], 40)
        self.assertLessEqual(pit["groundSpread"], ta.LEVEL)
        self.assertLess(pit["hollowShare"], 0.002)
        self.assertEqual(self.summary["totals"]["usgs-3dep-13"]["candidates"], 1)
        self.assertEqual(self.summary["totals"]["usgs-3dep-13"]["steep"], 2)
        # The block of zeros lies in the mrdem-30 half.
        self.assertEqual(self.summary["totals"]["nrcan-mrdem-30"]["candidates"], 1)

    def test_a_quarry_copernicus_does_not_show_is_steep_but_too_wide_for_a_candidate(self):
        quarry, = self.near(NEW_QUARRY, 14, 16)
        self.assertGreater(quarry["posts"], 100)
        self.assertGreater(quarry["furtherUnderOpened"], ta.HIDDEN)
        self.assertLessEqual(quarry["groundSpread"], ta.LEVEL)
        self.assertGreater(quarry["hollowShare"], ta.NARROW)
        self.assertFalse(quarry["candidate"])

    def test_a_block_of_zero_heights_is_a_candidate_however_wide(self):
        block, = self.near(ZEROS, 14, 14)
        self.assertGreater(block["hollowShare"], ta.NARROW)
        self.assertTrue(block["zeros"] and block["candidate"])
        self.assertEqual((block["lowest"], block["source"]), (0, "nrcan-mrdem-30"))

    def test_the_quarry_and_the_hills_basins_are_left_out_because_copernicus_shows_them(self):
        for group in self.steep:
            self.assertFalse(QUARRY[0] - 10 <= (44 - group["latitude"]) * 3600 <= QUARRY[0] + 30
                             and QUARRY[1] - 10 <= (group["longitude"] + 80) * 3600 <= QUARRY[1] + 38, group)
        # The quarry and at least a dozen basins of the hills.
        self.assertGreater(self.row()["copernicusShows"], 12)
        self.assertEqual(self.summary["copernicusShows"], self.row()["copernicusShows"])

    def test_a_slot_in_rugged_ground_is_steep_but_no_candidate(self):
        latitude, longitude = place(*self.slot)
        slot = [group for group in self.steep
                if abs(group["latitude"] - latitude) < 3 / 3600 and abs(group["longitude"] - longitude) < 3 / 3600]
        self.assertEqual(len(slot), 1, self.steep)
        self.assertFalse(slot[0]["candidate"])
        self.assertGreater(slot[0]["groundSpread"], ta.LEVEL)
        self.assertEqual(slot[0]["source"], "nrcan-mrdem-30")
        # The slot and the block of zeros.
        self.assertEqual(self.summary["totals"]["nrcan-mrdem-30"]["steep"], 2)

    def test_a_pit_the_hybrid_took_from_copernicus_is_not_a_hollow(self):
        latitude, longitude = place(*DROPPED)
        for group in self.steep:
            self.assertFalse(abs(group["latitude"] - latitude) < 10 / 3600
                             and abs(group["longitude"] - longitude) < 10 / 3600, group)

    def test_posts_far_below_a_flat_opened_surface_are_counted_by_source(self):
        counts = self.row()["sources"]
        # The pit's nine posts lie 53 m under the forest's top, which is flat there.
        self.assertEqual(counts["usgs-3dep-13"]["flatBelow50"], 9)
        self.assertEqual(counts["usgs-3dep-13"]["flatBelow50Carried"], 9)
        # The block of zeros 158 m under it, and the slot 68 m under the hills' surface, which is not flat.
        self.assertEqual(counts["nrcan-mrdem-30"]["flatBelow50"], 196)
        self.assertEqual(counts["nrcan-mrdem-30"]["below50"], 196 + 4)
        self.assertEqual(self.row()["deepestBelowFlat"]["source"], "nrcan-mrdem-30")
        self.assertEqual(self.row()["deepestBelowFlat"]["terrain"], 0)
        self.assertEqual(self.summary["totals"]["usgs-3dep-13"]["cellsFlatBelow50"], 1)
        self.assertEqual(self.row()["rejectedPixels"], 25)

    def test_a_cell_without_a_hybrid_tile_is_skipped_and_named(self):
        skipped = next(row for row in self.summary["rows"] if row["cell"] == "N43W081")
        self.assertEqual(skipped["skipped"], "no terrain and no opened and no hybrid tile")
        self.assertEqual((self.summary["cells"], self.summary["skipped"]), (2, 1))

    def test_each_steep_group_keeps_a_patch_of_the_hybrid_around_it(self):
        pit, = self.near(PIT, 3, 3)
        patch_ = pit["patch"]
        self.assertEqual((len(patch_["rows"]), len(patch_["rows"][0])), (3 + 2 * ta.PATCH, 3 + 2 * ta.PATCH))
        self.assertEqual(patch_["rows"][ta.PATCH + 1][ta.PATCH + 1], round(150 + 0.002 * (PIT[1] + 1) - 45))
        self.assertGreaterEqual(patch_["closed"][ta.PATCH + 1][ta.PATCH + 1], 40)
        self.assertEqual(patch_["closed"][0][0], 0)

    def roads(self, edges, broken=False, **options):
        FakeValhalla.edges, FakeValhalla.broken, FakeValhalla.asked = edges, broken, []
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeValhalla)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        out = self.root / ("roads-broken" if broken else "roads")
        out.mkdir(exist_ok=True)
        (out / "pits.jsonl.gz").write_bytes((self.root / "out" / "pits.jsonl.gz").read_bytes())
        (out / "scan.json").write_bytes((self.root / "out" / "scan.json").read_bytes())
        options = {"jobs": 2, **options}
        status = ta.roads(out, f"http://127.0.0.1:{server.server_address[1]}", say=lambda _text: None, wait=0, **options)
        with gzip.open(out / "roads.json.gz", "rt") as stream:
            return status, json.load(stream), out

    def road_edges(self):
        latitude, longitude = place(PIT[0] + 1, PIT[1] + 1)
        across = [(latitude, longitude - 0.002), (latitude, longitude + 0.002)]
        north = 2.5 / 3600
        return [
            edge(across, 1, "residential"),
            edge(across[::-1], 1, "residential"),
            edge([(lat + 0.00001, lon) for lat, lon in across], 2, "primary", "road", "paved", bridge=True),
            # A track a post and a half north of the pit's top row: near it, but on the plain.
            edge([(lat + north, lon) for lat, lon in across], 3, "service_other", "track", "dirt"),
            edge([(latitude + 0.01, longitude - 0.002), (latitude + 0.01, longitude + 0.002)], 4, "tertiary"),
        ]

    def test_a_road_across_the_pit_has_a_false_step_and_the_rest_do_not(self):
        status, found, _ = self.roads(self.road_edges())
        self.assertEqual((status, found["failed"]), (0, []))
        self.assertEqual(found["groups"], len(self.steep))
        ways = {record["way"]: record for record in found["edges"]}
        # Way 4 lies a kilometre away and is never measured.
        self.assertEqual(set(ways), {1, 2, 3})
        road = ways[1]
        self.assertTrue(road["falseStep"])
        self.assertGreater(road["dip"], 40)
        self.assertGreaterEqual(road["grade"], 1.0)
        self.assertLessEqual(road["gradePitFilled"], 0.05)
        self.assertEqual((road["category"], road["paved"], road["pit"]["candidate"]), ("minor public road", True, True))
        self.assertEqual(road["storedSlopes"]["max_up_slope"], 61.0)
        self.assertIn("shape", road)
        self.assertTrue(ways[2]["falseStep"] and ways[2]["bridge"])
        self.assertFalse(ways[3]["falseStep"])
        self.assertNotIn("shape", ways[3])
        self.assertLess(ways[3]["metresToPit"], ta.NEAR)
        # Every request asked with bicycle costing, within Valhalla's largest radius.
        self.assertEqual({body["costing"] for body in FakeValhalla.asked}, {"bicycle"})
        self.assertEqual({location["radius"] for body in FakeValhalla.asked for location in body["locations"]},
                         {ta.RADIUS})

    def test_the_report_counts_ways_by_class_and_lists_the_worst(self):
        _, _, out = self.roads(self.road_edges())
        report = ta.report(out, sample=True, say=lambda _text: None)
        self.assertEqual(report["candidates"], 2)
        self.assertEqual(report["sources"]["usgs-3dep-13"]["artifactCandidates"], 1)
        self.assertEqual(report["sources"]["nrcan-mrdem-30"]["steepHollows"], 2)
        self.assertEqual(report["roads"]["public"], {"ways": 1, "paved": 1, "unpaved": 0})
        self.assertEqual(report["roads"]["publicByClass"], {"residential": {"ways": 1, "paved": 1, "unpaved": 0}})
        self.assertEqual(report["roads"]["leftOut"], {"bridges": 1, "tunnels": 0})
        self.assertEqual(report["roads"]["publicAtCandidates"], 1)
        self.assertEqual(report["roads"]["falseSteps"]["track"]["ways"], 0)
        # One row a way, though the way has an edge each way.
        self.assertEqual([entry["way"] for entry in report["worstPublicRoads"]], [1])
        # The block of zeros is the deepest candidate; the pit is the one a road crosses.
        self.assertEqual([entry["falseStepOnARoad"] for entry in report["deepestCandidates"]], [False, True])
        self.assertEqual(report["headline"], "2 artifact candidates (nrcan-mrdem-30 1, usgs-3dep-13 1); 1 public-road "
                                             "way with a false step (1 paved, 0 unpaved)")
        text = (out / "terrain-report.md").read_text()
        self.assertIn("A city sample rehearsal, not release evidence.", text)
        self.assertIn("| residential | 1 | 1 | 0 |", text)
        self.assertIn("1 of the 1 public-road way lie at an artifact candidate.\n", text)
        self.assertIn("Way 1, residential, paved_smooth (way 1)", text)
        self.assertEqual(json.loads((out / "terrain-report.json").read_text())["headline"], report["headline"])

    def test_a_failed_lookup_fails_the_command_and_is_reported(self):
        status, found, out = self.roads(self.road_edges(), broken=True)
        self.assertEqual(status, 1)
        self.assertEqual(len(found["failed"]), len(self.steep))
        self.assertIn("/locate failed 4 times", found["failed"][0]["error"])
        report = ta.report(out, say=lambda _text: None)
        self.assertEqual(report["roads"]["lookupsFailed"], len(self.steep))
        self.assertTrue(report["headline"].endswith(f"{len(self.steep)} lookups FAILED"), report["headline"])

    def test_a_service_that_stops_answering_is_not_asked_for_every_hollow(self):
        status, found, _ = self.roads(self.road_edges(), broken=True, jobs=1, stop_after=1)
        self.assertEqual(status, 1)
        self.assertEqual(len(found["failed"]), len(self.steep))
        # The first hollow was asked four times; the others not at all.
        self.assertEqual(len(FakeValhalla.asked), 4)
        self.assertEqual(found["failed"][-1]["error"], "not looked up: the service had stopped answering")

    def test_without_a_road_check_the_report_says_so(self):
        out = self.root / "scan-only"
        out.mkdir(exist_ok=True)
        for name in ("pits.jsonl.gz", "scan.json"):
            (out / name).write_bytes((self.root / "out" / name).read_bytes())
        report = ta.report(out, say=lambda _text: None)
        self.assertIsNone(report["roads"])
        self.assertIn("roads not checked", report["headline"])
        self.assertIn("The roads were not checked.", (out / "terrain-report.md").read_text())


class MeasureTests(unittest.TestCase):
    def item(self, rows):
        group = {"latitude": 43.5, "longitude": -79.5, "source": "nrcan-mrdem-30", "closedDepth": 40, "lowest": 60,
                 "steepestStep": 40, "furtherUnderOpened": 40, "groundSpread": 5, "candidate": True, "posts": 9}
        import numpy as np

        depth = ta.closed_depth(np.array(rows, dtype="float32"), 6, 43.5)
        group["patch"] = {"north": 43.5 + 8 / 3600, "west": -79.5 - 8 / 3600, "rows": rows,
                          "closed": [[int(round(value)) if value > 0 else 0 for value in line] for line in depth]}
        return ta.prepare("N43W080", 0, group)

    def road(self, item, offset=0.0):
        north, west = item["north"], item["west"]
        lat = north - (8 + offset) / 3600
        return ta.along([(lat, west + 1 / 3600), (lat, west + 17 / 3600)])

    def test_a_road_that_dives_into_a_pit_has_a_false_step(self):
        rows = [[100] * 19 for _ in range(19)]
        for r in range(7, 10):
            for c in range(7, 10):
                rows[r][c] = 60
        item = self.item(rows)
        found = ta.effect(item, self.road(item), ta.filled_grid(rows, item["holes"]))
        self.assertTrue(found["falseStep"])
        self.assertEqual((found["dip"], found["height"], found["heightPitFilled"]), (40.0, 60.0, 100.0))
        self.assertEqual(found["gradePitFilled"], 0.0)

    def test_a_shallow_dent_or_a_real_hill_is_no_false_step(self):
        dent = [[100] * 19 for _ in range(19)]
        for r in range(7, 10):
            for c in range(7, 10):
                dent[r][c] = 96
        item = self.item(dent)
        self.assertFalse(ta.effect(item, self.road(item), ta.filled_grid(dent, item["holes"]))["falseStep"])
        # A 30% hill along the road, with a pit in it: steep with the pit filled too.
        hill = [[100 + 0.3 * 22.4 * c for c in range(19)] for _ in range(19)]
        for r in range(7, 10):
            for c in range(7, 10):
                hill[r][c] -= 40
        item = self.item(hill)
        found = ta.effect(item, self.road(item), ta.filled_grid(hill, item["holes"]))
        self.assertGreater(found["dip"], 30)
        self.assertGreater(found["gradePitFilled"], ta.FILLED_GRADE)
        self.assertFalse(found["falseStep"])

    def test_points_along_a_shape_lie_ten_metres_apart(self):
        start = (45.0, 7.0)
        east = 10 / (ta.METRES * math.cos(math.radians(45.0)))
        shape = [start, (45.0, 7.0 + 2.5 * east), (45.0, 7.0 + 2.5 * east), (45.0, 7.0 + 4.25 * east)]
        points = ta.along(shape)
        self.assertEqual(len(points), 6)
        steps = [(b[1] - a[1]) / east * 10 for a, b in zip(points, points[1:])]
        for step in steps[:-1]:
            self.assertAlmostEqual(step, 10, places=6)
        self.assertAlmostEqual(steps[-1], 2.5, places=6)
        self.assertEqual(ta.along([start]), [start])

    def test_the_encoded_shape_reads_back(self):
        points = [(45.623291, -76.547891), (45.62331, -76.54701), (45.6, -76.5)]
        self.assertEqual(ta.decode(encode(points)), points)

    def test_east_and_west_the_reach_covers_as_many_metres_as_north_and_south(self):
        import numpy as np

        # A trench running north-south, open to the north and south: no closed hollow.
        heights = np.full((61, 61), 100, dtype="float32")
        heights[:, 30] = 50
        self.assertEqual(float(np.nanmax(ta.closed_depth(heights, 12, 60.0))), 0)
        # Walls 20 posts east and west close it at 60 degrees north, where 12 posts north are 24 posts east.
        heights[:, :] = 50
        heights[:, 10] = heights[:, 50] = 100
        heights[18, :] = heights[42, :] = 100
        depth = ta.closed_depth(heights, 12, 60.0)
        self.assertEqual(float(depth[30, 30]), 50)
        self.assertEqual(float(ta.closed_depth(heights, 12, 0.0)[30, 30]), 0)

    def test_a_post_belongs_to_the_first_source_whose_area_holds_it(self):
        import numpy as np

        sources = build_elevation.load_terrain_sources(ta.SOURCES)
        ids = [source.id for source in sources][:2]
        self.assertEqual(ta.source_masks(CELL, ids[:1], sources), {ids[0]: None})
        half = np.zeros((POSTS, POSTS), dtype=bool)
        half[:, :100] = True
        with patch.object(build_elevation, "posts_in_area", lambda _cell, area: half if area == ids[0] else True), \
                patch.object(build_elevation, "load_area", lambda path, _sha: next(
                    source.id for source in sources if source.area == path)):
            masks = ta.source_masks(CELL, ids, sources)
        self.assertEqual(int(masks[ids[0]].sum()), POSTS * 100)
        self.assertEqual(int(masks[ids[1]].sum()), POSTS * (POSTS - 100))
        with self.assertRaisesRegex(ValueError, "does not hold"):
            ta.source_masks(CELL, [ids[0], "unknown-dtm"], sources)


if __name__ == "__main__":
    unittest.main()
