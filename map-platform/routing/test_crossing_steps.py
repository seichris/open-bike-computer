import gzip
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import build_elevation
import crossing_steps

POSTS = build_elevation.POSTS
STEP = crossing_steps.STEP

# A small extract around 40.5 N, 79.5 W, in the middle of cell N40W080. Longitudes step 0.0005 degrees,
# about 42 m. Each road runs east and west; what it crosses runs north and south.
ROWS = {"untagged": 40.5000, "culvert": 40.5050, "bridge": 40.5100, "ford": 40.5150, "tunnel": 40.5200}


def node(number, lat, lon, tags=None):
    inner = "".join(f'<tag k="{k}" v="{v}"/>' for k, v in (tags or {}).items())
    return f'<node id="{number}" version="1" lat="{lat:.7f}" lon="{lon:.7f}">{inner}</node>'


def way(number, nodes, tags):
    refs = "".join(f'<nd ref="{n}"/>' for n in nodes)
    inner = "".join(f'<tag k="{k}" v="{v}"/>' for k, v in tags.items())
    return f'<way id="{number}" version="1">{refs}{inner}</way>'


def extract(extra_nodes=(), extra_ways=(), relations=""):
    nodes, ways = list(extra_nodes), list(extra_ways)

    def road(first, lat, lons, tags, number):
        ids = list(range(first, first + len(lons)))
        nodes.extend(node(i, lat, lon) for i, lon in zip(ids, lons))
        ways.append(way(number, ids, tags))
        return ids

    def water(first, lon, lat, tags, number, through=None):
        ids = [first, first + 1] if through is None else [first, through, first + 1]
        nodes.append(node(first, lat - 0.001, lon))
        nodes.append(node(first + 1, lat + 0.001, lon))
        ways.append(way(number, ids, tags))

    lons = [-79.503 + 0.0005 * i for i in range(13)]
    road(1, ROWS["untagged"], lons, {"highway": "residential", "name": "Plain Road"}, 1)
    water(1001, -79.49975, ROWS["untagged"], {"waterway": "stream", "name": "Run"}, 101)
    road(21, ROWS["culvert"], lons, {"highway": "tertiary"}, 2)
    water(1011, -79.49975, ROWS["culvert"], {"waterway": "stream", "tunnel": "culvert"}, 102)
    # A bridge of two segments between two approaches; a river and a path pass beneath it.
    lat = ROWS["bridge"]
    approach = road(41, lat, [-79.503 + 0.0005 * i for i in range(5)], {"highway": "primary"}, 3)
    nodes.append(node(46, lat, -79.5005))
    nodes.append(node(47, lat, -79.5000))
    ways.append(way(4, [approach[-1], 46, 47], {"highway": "primary", "bridge": "yes", "name": "River Bridge"}))
    far = list(range(48, 52))
    nodes.extend(node(i, lat, -79.5000 + 0.0005 * (i - 47)) for i in far)
    ways.append(way(5, [47, *far], {"highway": "primary"}))
    water(1021, -79.50075, lat, {"waterway": "river"}, 103)
    nodes.append(node(61, lat - 0.0005, -79.5008))
    nodes.append(node(62, lat + 0.0005, -79.5008))
    ways.append(way(6, [61, 62], {"highway": "path"}))
    # A track through a ford: the stream shares its node, tagged as a ford.
    lat = ROWS["ford"]
    track = road(71, lat, [-79.501 + 0.0005 * i for i in range(5)], {"highway": "track"}, 7)
    nodes[-3] = node(track[2], lat, -79.5, {"ford": "yes"})
    water(1031, -79.5, lat, {"waterway": "stream"}, 104, through=track[2])
    # A tunnel between two roads.
    lat = ROWS["tunnel"]
    road(81, lat, [-79.503 + 0.0005 * i for i in range(5)], {"highway": "secondary"}, 8)
    nodes.append(node(86, lat, -79.5005))
    ways.append(way(9, [85, 86, 87], {"highway": "secondary", "tunnel": "yes"}))
    nodes.append(node(87, lat, -79.5000))
    road(88, lat, [-79.4995 + 0.0005 * i for i in range(4)], {"highway": "secondary"}, 10)
    ways[-1] = way(10, [87, 88, 89, 90, 91], {"highway": "secondary"})
    # A footway bikes may not use, over the same stream as the plain road.
    nodes.append(node(201, ROWS["untagged"] + 0.0003, -79.501))
    nodes.append(node(202, ROWS["untagged"] + 0.0003, -79.498))
    ways.append(way(11, [201, 202], {"highway": "footway"}))
    by_id = sorted(nodes, key=lambda text: int(text.split('"')[1]))
    body = "".join(by_id) + "".join(sorted(ways, key=lambda text: int(text.split('"')[1]))) + relations
    return f'<?xml version="1.0"?><osm version="0.6" generator="test">{body}</osm>'


class RuleTests(unittest.TestCase):
    def test_roads_bikes_may_use(self):
        self.assertEqual(crossing_steps.bikes_may_use({"highway": "residential"}), "minor")
        self.assertEqual(crossing_steps.bikes_may_use({"highway": "track"}), "track")
        self.assertIsNone(crossing_steps.bikes_may_use({"highway": "footway"}))
        self.assertEqual(crossing_steps.bikes_may_use({"highway": "footway", "bicycle": "yes"}), "path")
        self.assertIsNone(crossing_steps.bikes_may_use({"highway": "motorway"}))
        self.assertIsNone(crossing_steps.bikes_may_use({"highway": "primary", "access": "private"}))
        self.assertIsNone(crossing_steps.bikes_may_use({"highway": "primary", "bicycle": "no"}))
        self.assertIsNone(crossing_steps.bikes_may_use({"highway": "steps"}))

    def test_surfaces_and_structures(self):
        self.assertEqual(crossing_steps.surface_of({"highway": "track"}), "unpaved")
        self.assertEqual(crossing_steps.surface_of({"highway": "track", "surface": "asphalt"}), "paved")
        self.assertEqual(crossing_steps.surface_of({"highway": "primary"}), "paved")
        self.assertEqual(crossing_steps.surface_of({"highway": "primary", "surface": "gravel"}), "unpaved")
        # Every bridge value but no, false and 0 is a bridge, as build_graph.py --all-bridges has it.
        self.assertTrue(crossing_steps.is_bridge({"bridge": "movable"}))
        self.assertFalse(crossing_steps.is_bridge({"bridge": "no"}))
        self.assertTrue(crossing_steps.is_tunnel({"tunnel": "building_passage"}))
        self.assertFalse(crossing_steps.is_tunnel({"tunnel": "culvert"}))
        self.assertEqual(crossing_steps.waterway_of({"waterway": "ditch", "tunnel": "culvert"}), ("drain", True))
        self.assertEqual(crossing_steps.waterway_of({"waterway": "river"}), ("river", False))
        self.assertIsNone(crossing_steps.waterway_of({"waterway": "dam"}))


class SiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        path = Path(cls.directory.name) / "test.osm"
        path.write_text(extract())
        roads, waters, fords = crossing_steps.read_ways(path)
        cls.roads = roads
        cls.sites = crossing_steps.find_sites(roads, waters, fords, [], log=lambda *_: None)
        cls.by_kind = {}
        for site in cls.sites:
            cls.by_kind.setdefault(site[0]["kind"], []).append(site)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_each_kind_of_crossing_is_found_once(self):
        self.assertEqual({kind: len(found) for kind, found in self.by_kind.items()},
                         {"untagged": 1, "culvert": 1, "bridge-water": 1, "ford": 1, "tunnel": 1})
        # The footway is no road for bikes, so its crossing of the same stream is no site.
        self.assertNotIn(11, self.roads.ids.tolist())

    def test_a_crossing_reaches_along_the_road_both_ways(self):
        record, side_a, side_b, _ = self.by_kind["untagged"][0]
        self.assertEqual((record["way"], record["waterKind"], record["waterName"]), (1, "stream", "Run"))
        self.assertAlmostEqual(record["lon"], -79.49975, places=6)
        # The road runs 275 m west and 233 m east of the stream; each side reaches 150 m.
        self.assertEqual((len(side_a[0]), len(side_b[0])), (31, 31))
        self.assertLess(side_a[0][-1], side_a[0][0])
        self.assertEqual(record["protected"], [])

    def test_a_bridge_spans_its_chain_and_keeps_the_path_beneath(self):
        record, side_a, side_b, _ = self.by_kind["bridge-water"][0]
        self.assertEqual(record["ways"], [4])
        self.assertAlmostEqual(record["spanLength"], 0.001 * 111320 * 0.7604, delta=1.5)
        self.assertEqual(sorted(record["nodes"]), [45, 47])
        # Its sides start at the bridge's ends and run out along the approaches.
        self.assertAlmostEqual(side_a[0][0], -79.501, places=6)
        self.assertAlmostEqual(side_b[0][0], -79.500, places=6)
        self.assertEqual(set(side_a[3].tolist()) | set(side_b[3].tolist()), {3, 5})
        # The path crosses the bridge's line without a node of its own there: its points are kept.
        self.assertTrue(record["protected"])
        self.assertTrue(all(abs(lon + 79.5008) < 1e-6 for lon, _ in record["protected"]))

    def test_a_tunnel_is_a_chain_and_a_ford_is_listed(self):
        record = self.by_kind["tunnel"][0][0]
        self.assertEqual((record["span"], record["ways"]), (crossing_steps.SPAN_TUNNEL, [9]))
        self.assertEqual(self.by_kind["ford"][0][0]["way"], 7)

    def test_sites_round_trip_through_their_file(self):
        with tempfile.TemporaryDirectory() as directory:
            writer = crossing_steps.SiteWriter()
            for record, side_a, side_b, _ in self.sites:
                writer.add(dict(record), side_a, side_b)
            path = Path(directory) / "sites.npz"
            writer.save(path, {"region": "test", "source": "test.osm", "sourceSha256": "0" * 64})
            meta, lons, lats, flags, ways, offsets = crossing_steps.load_sites(path)
        self.assertEqual(len(meta["sites"]), len(self.sites))
        self.assertEqual(len(offsets), 2 * len(self.sites) + 1)
        self.assertEqual(len(lons), offsets[-1])
        self.assertEqual(ways.dtype.kind, "i")
        self.assertFalse(flags.any())


def sides(profile_a, profile_b):
    """Heights outward from the two ends, at STEP metres."""
    import numpy as np

    return np.asarray(profile_a, dtype=float), np.asarray(profile_b, dtype=float)


def notch(depth, half_width_points, length=31):
    """A level road at 100 m with a V-shaped notch at its first point."""
    import numpy as np

    heights = np.full(length, 100.0)
    for i in range(half_width_points):
        heights[i] = 100.0 - depth * (1 - i / half_width_points)
    return heights


class MeasureTests(unittest.TestCase):
    def test_a_channel_under_a_level_road_is_a_false_step(self):
        side = notch(10, 4)
        result = crossing_steps.measure_site({"kind": "culvert", "span": 0, "spanLength": 0.0}, side, side)
        self.assertTrue(result["falseStep"])
        self.assertEqual((result["grade"] >= 0.30, result["bridgedGrade"]), (True, 0.0))
        self.assertEqual(result["dip"], 10.0)

    def test_a_real_valley_is_no_false_step(self):
        import numpy as np

        # 8% down to the stream and up again, the way a country road dips through a valley.
        side = 100.0 + 0.08 * STEP * np.arange(31)
        result = crossing_steps.measure_site({"kind": "untagged", "span": 0, "spanLength": 0.0}, side, side)
        self.assertFalse(result["falseStep"])
        self.assertFalse(result["falseGrade"])
        self.assertAlmostEqual(result["grade"], 0.08, places=3)

    def test_low_bridge_ends_are_a_false_step_and_the_deck_is_not_judged(self):
        a, b = notch(12, 3), notch(12, 3)
        record = {"kind": "bridge-water", "span": crossing_steps.SPAN_BRIDGE, "spanLength": 120.0}
        result = crossing_steps.measure_site(record, a, b)
        self.assertTrue(result["falseStep"])
        # A long bridge whose ends differ by 30 m reads 25% along the deck: Valhalla clamps that edge.
        import numpy as np

        level = np.full(31, 100.0)
        result = crossing_steps.measure_site(record, level, level + 30)
        self.assertLess(result["grade"], 0.30)

    def test_a_bridge_on_a_side_is_graded_from_its_ends(self):
        import numpy as np

        side = np.full(31, 100.0)
        side[10:15] = 80.0
        flags = np.zeros(31, bool)
        flags[9:16] = True
        heights = crossing_steps.bridge_runs(side, flags)
        self.assertTrue(np.all(heights == 100.0))
        # A bridge that runs off the end of the walk has no height there.
        flags[:] = False
        flags[25:] = True
        self.assertTrue(np.isnan(crossing_steps.bridge_runs(side, flags)[25:]).all())

    def test_a_tunnel_hump_is_cut_not_filled(self):
        import numpy as np

        record = {"kind": "tunnel", "span": crossing_steps.SPAN_TUNNEL, "spanLength": 200.0}
        hump = np.full(31, 100.0)
        hump[:4] = [140.0, 130.0, 120.0, 110.0]
        result = crossing_steps.measure_site(record, hump, hump)
        self.assertTrue(result["falseStep"])


class KeptSetTests(unittest.TestCase):
    def test_a_cell_is_read_from_its_band_by_range_and_checked(self):
        import numpy as np
        import elevation_cache

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tiles = root / "tiles"
            cells = {}
            for name, value in (("N40W080", 100), ("N41W080", 200), ("N40W079", 300)):
                posts = np.full((POSTS, POSTS), value, dtype=">i2")
                payload = posts.tobytes()
                path = tiles / name[:3] / f"{name}.hgt.gz"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(gzip.compress(payload, mtime=0))
                cells[name] = (hashlib.sha256(payload).hexdigest(), path.stat().st_size)
            listing = "".join(f"{name} {sha}\n" for name, (sha, _) in sorted(cells.items())).encode()
            manifest = json.dumps({"schema": "bicino-valhalla-elevation-v1", "method": {"name": "test"},
                                   "sources": [{"id": "test", "cells": 3}]}).encode()
            (tiles / "cells.txt").write_bytes(listing)
            (tiles / "elevation-manifest.json").write_bytes(manifest)
            (tiles / "receipts").mkdir()
            for name, (sha, size) in cells.items():
                (tiles / "receipts" / f"{name}.json").write_text(json.dumps({"cell": name, "hgtSha256": sha,
                                                                              "fileBytes": size}))
            shards = [elevation_cache.write_tar(root / "N4.tar", tiles, sorted(f"{c[:3]}/{c}.hgt.gz" for c in cells)),
                      elevation_cache.write_tar(root / "meta.tar", tiles,
                                                sorted(f"receipts/{c}.json" for c in cells)
                                                + ["cells.txt", "elevation-manifest.json"])]
            record = root / "record.json"
            record.write_text(json.dumps({"bucket": "b", "sets": {"hybrid-400": {
                "prefix": "p/", "cellListSha256": hashlib.sha256(listing).hexdigest(),
                "manifestSha256": hashlib.sha256(manifest).hexdigest(), "shards": shards}}}))
            kept = crossing_steps.KeptSet(record, "hybrid-400", None, root / "meta.tar")
            band = (root / "N4.tar").read_bytes()
            kept.read = lambda shard, start, end: band[start:end + 1]
            self.assertEqual(float(kept.fetch("N41W080")[1800, 1800]), 200.0)
            self.assertEqual(float(kept.fetch("N40W079")[0, 0]), 300.0)
            self.assertIsNone(kept.fetch("N10W010"))
            kept.cells["N40W080"] = "0" * 64
            with self.assertRaises(RuntimeError):
                kept.fetch("N40W080")


class SplitTests(unittest.TestCase):
    """crossing_split.py on the small extract, over a tile with channels under the plain road and the bridge."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def tile_set(self):
        import numpy as np
        from sample_elevation import write_hgt, write_manifest

        heights = np.full((POSTS, POSTS), 100.0, dtype="float32")
        # The stream under the plain road (79.49975 W, 40.5 N) and the river under the bridge (79.50075 W).
        heights[1790:1810, 1800:1802] = 85.0
        heights[1755:1775, 1797:1799] = 85.0
        out = self.root / "elevation"
        out.mkdir()
        entry = write_hgt(out, (-80, 40), heights)
        write_manifest(out, {"name": "terrain-over-opening"}, [{"id": "usgs-3dep-13"}], [entry], [-80, 40, -79, 41])
        return out

    def extract(self):
        """The test extract with a bicycle route over the plain road and a turn restriction at its east end."""
        relations = ('<relation id="501" version="3"><member type="way" ref="1" role=""/>'
                     '<tag k="route" v="bicycle"/><tag k="type" v="route"/></relation>'
                     '<relation id="502" version="1"><member type="way" ref="1" role="from"/>'
                     '<member type="node" ref="13" role="via"/><member type="way" ref="12" role="to"/>'
                     '<tag k="restriction" v="no_left_turn"/><tag k="type" v="restriction"/></relation>')
        north = node(301, ROWS["untagged"] + 0.002, -79.497)
        path = self.root / "roads.osm"
        path.write_text(extract([north], [way(12, [13, 301], {"highway": "residential"})], relations))
        return path

    def sites(self, roads):
        loaded, waters, fords = crossing_steps.read_ways(roads)
        writer = crossing_steps.SiteWriter()
        for record, side_a, side_b, _ in crossing_steps.find_sites(loaded, waters, fords, [], log=lambda *_: None):
            writer.add(record, side_a, side_b)
        path = self.root / "sites.npz"
        writer.save(path, {"region": "test", "source": roads.name, "sourceSha256": "0" * 64})
        return path

    def read(self, path):
        import osmium

        ways, relations = {}, {}
        for item in osmium.FileProcessor(str(path), osmium.osm.WAY | osmium.osm.RELATION):
            if item.is_way():
                ways[item.id] = (dict(item.tags), [n.ref for n in item.nodes])
            else:
                relations[item.id] = [(m.type, m.ref, m.role) for m in item.members]
        return ways, relations

    def test_the_road_over_a_channel_and_the_bridge_ends_are_graded_from_their_ends(self):
        import crossing_split

        roads = self.extract()
        out = self.root / "roads-crossings.osm.pbf"
        record, fixed = crossing_split.run(roads, [self.sites(roads)], self.tile_set(), out, jobs=1,
                                           log=lambda *_: None)
        self.assertEqual(sorted(site["kind"] for site in fixed), ["bridge-water", "untagged"])
        ways, relations = self.read(out)
        # The plain road is cut on solid ground either side of the stream; the piece between is a bridge now.
        pieces = [way_id for way_id, (tags, _) in ways.items() if tags.get("name") == "Plain Road"]
        self.assertEqual(len(pieces), 3)
        graded = [way_id for way_id in pieces if ways[way_id][0].get(crossing_split.TAG) == "crossing"]
        self.assertEqual(len(graded), 1)
        self.assertEqual(ways[graded[0]][0]["bridge"], "yes")
        self.assertIn(1, pieces)
        self.assertTrue(all(way_id >= crossing_split.WAY_BASE for way_id in pieces if way_id != 1))
        # The approaches of the river bridge are cut too, and the bridge itself stays as it was.
        self.assertTrue(any(ways[way_id][0].get(crossing_split.TAG) for way_id in ways
                            if ways[way_id][0].get("highway") == "primary"))
        self.assertNotIn(crossing_split.TAG, ways[4][0])
        # The bicycle route holds every piece; the restriction the piece that touches its via node.
        self.assertEqual(sorted(ref for kind, ref, _ in relations[501] if kind == "w"), sorted(pieces))
        from_ways = [ref for kind, ref, role in relations[502] if role == "from"]
        self.assertEqual(len(from_ways), 1)
        self.assertEqual(ways[from_ways[0]][1][-1], 13)
        # Nothing else changed: the culvert's road has no low point and the stream's line is untouched.
        self.assertNotIn(crossing_split.TAG, ways[2][0])
        self.assertEqual((record["fixedSites"], record["relationsChanged"]), (2, 2))
        subprocess_run = __import__("subprocess").run
        subprocess_run(["osmium", "check-refs", "--check-relations", str(out)], check=True, capture_output=True)

    def test_a_level_road_stays_as_it_was(self):
        import numpy as np
        import crossing_split
        from sample_elevation import write_hgt, write_manifest

        out = self.root / "level"
        out.mkdir()
        entry = write_hgt(out, (-80, 40), np.full((POSTS, POSTS), 100.0, dtype="float32"))
        write_manifest(out, {"name": "terrain-over-opening"}, [{"id": "usgs-3dep-13"}], [entry], [-80, 40, -79, 41])
        roads = self.extract()
        record, fixed = crossing_split.run(roads, [self.sites(roads)], out, self.root / "same.osm.pbf", jobs=1,
                                           log=lambda *_: None)
        self.assertEqual((fixed, record["waysChanged"]), ([], 0))
        self.assertEqual(self.read(self.root / "same.osm.pbf"), self.read(roads))

    def test_pieces_and_members(self):
        import crossing_split

        nodes = [(1, -79.5, 40.5), (2, -79.499, 40.5), (3, -79.498, 40.5)]
        stretch = ([-79.4996, -79.4993, -79.499, -79.4987], [40.5] * 4)
        plan = {"cuts": [(-79.4996, 40.5), (-79.4987, 40.5)], "stretches": [stretch]}
        pieces, made = crossing_split.split_way(7, nodes, {"highway": "residential"}, plan, crossing_split.Ids())
        self.assertEqual([len(piece[1]) for piece in pieces], [2, 3, 2])
        self.assertEqual([piece[2].get("bridge") for piece in pieces], [None, "yes", None])
        self.assertEqual(pieces[0][0], 7)
        self.assertEqual(len(made), 2)
        # A cut within a metre of a node cuts there and makes no node.
        plan = {"cuts": [(-79.499005, 40.5)], "stretches": [([-79.499, -79.498], [40.5, 40.5])]}
        pieces, made = crossing_split.split_way(7, nodes, {"highway": "residential"}, plan, crossing_split.Ids())
        self.assertEqual(([piece[1] for piece in pieces], made), ([[1, 2], [2, 3]], []))
        relation = {"tags": {"type": "restriction"}, "members": [("w", 7, "from"), ("n", 3, "via"), ("w", 8, "to")]}
        replaced = crossing_split.members_after(relation, {7: pieces})
        self.assertEqual(replaced, [("w", pieces[1][0], "from"), ("n", 3, "via"), ("w", 8, "to")])
        self.assertIsNone(crossing_split.members_after(relation, {9: pieces}))


class BuildFlagTests(unittest.TestCase):
    def test_crossings_need_the_elevation_they_read(self):
        import contextlib
        import io
        import sys
        from unittest.mock import patch

        import build_graph

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "roads.osm.pbf"
            source.write_bytes(b"roads")
            sites = Path(directory) / "sites.npz"
            sites.write_bytes(b"sites")
            argv = ["build_graph.py", "--sample", "--source", str(source), "--source-sha256",
                    hashlib.sha256(b"roads").hexdigest(), "--source-url", "https://example.org/roads",
                    "--work", str(Path(directory) / "work"), "--crossings", str(sites)]
            errors = io.StringIO()
            with patch.object(sys, "argv", argv), contextlib.redirect_stderr(errors), \
                    self.assertRaises(SystemExit):
                build_graph.main()
            self.assertIn("--crossings reads the road's heights from --elevation", errors.getvalue())
            self.assertFalse((Path(directory) / "work").exists())


class StoredTests(unittest.TestCase):
    def test_only_edges_matched_near_the_crossing_count(self):
        import numpy as np

        record = {"kind": "culvert", "span": 0, "spanLength": 0.0}
        lons = -79.5 + np.arange(31) * 6.5e-5
        side_a, side_b = (lons[::-1], np.full(31, 40.5)), (lons, np.full(31, 40.5))
        calls = []

        def post(origin, path, body):
            calls.append(body)
            count = len(body["shape"])
            # Edge 0 ends 100 m before the crossing; edge 1 spans it; edge 2 starts 100 m after.
            points = [{"type": "matched", "edge_index": 0 if i < 10 else 2 if i > count - 11 else 1}
                      for i in range(count)]
            edges = [{"max_upward_grade": 40, "max_downward_grade": 0}, {"max_upward_grade": 12,
                     "max_downward_grade": -18, "weighted_grade": 5}, {"max_upward_grade": 0,
                     "max_downward_grade": -40}]
            return 200, {"edges": edges, "matched_points": points}

        result = crossing_steps.stored_at_site(post, "http://valhalla", record, side_a, side_b)
        self.assertEqual((result["maxSlope"], result["maxUp"], result["maxDown"]), (18, 12, -18))
        self.assertEqual(calls[0]["costing"], "bicycle")
        self.assertEqual(len(calls[0]["shape"]), 61)


if __name__ == "__main__":
    unittest.main()
