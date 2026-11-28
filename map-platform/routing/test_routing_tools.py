import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import unittest
import urllib.parse
import zipfile
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from shapely.geometry import Point, box, mapping

from build_graph import (
    ARCHIVE_NAME, INDEX_ENTRY, archive_tile_count, argument_error, elevation_identity, file_identity,
    graph_lua_identity, needs_all_bridges, prepare_inputs, valhalla_build,
)
from coverage_mask import DISPUTES, MAP_UNITS, build_mask, check_apple_list, mask_feature
from stage_graph import stage
import build_elevation
import compare_elevation
import graph_lua
import probe_graph
import probe_profiles
import sample_elevation
import terrain_catalog


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

        def run_pool(pending, chosen, out, jobs, opening=None, stage=None):
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

    def test_a_run_builds_every_cell_and_names_all_that_failed(self):
        from concurrent.futures import Future

        class Pool:
            """A pool that runs each cell at once, in this process."""

            def __init__(self, jobs, initializer, initargs):
                initializer(*initargs)

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def submit(self, function, cell):
                future = Future()
                try:
                    future.set_result(function(cell))
                except Exception as error:
                    future.set_exception(error)
                return future

        cells = [(8, 47), (9, 47), (10, 47), (11, 47), (12, 47)]
        built = []

        def build(cell):
            if cell in ((9, 47), (11, 47)):
                raise ValueError(f"garbage in {cell}")
            built.append(cell)

        printed = io.StringIO()
        with patch.object(build_elevation, "ProcessPoolExecutor", Pool), patch.object(build_elevation, "_build", build), \
                patch.dict(build_elevation._WORKER), patch("sys.stdout", printed):
            with self.assertRaisesRegex(build_elevation.CellsFailed, "^2 of 5 cells failed: N47E009 N47E011$"):
                build_elevation.run_pool(cells, {}, Path("."), 2)
            # The cells after a failed one were still built, and each failure has its line.
            self.assertEqual(built, [(8, 47), (10, 47), (12, 47)])
            self.assertIn("N47E009 failed: ValueError: garbage in (9, 47)\n", printed.getvalue())
            self.assertIn("N47E011 failed: ValueError: garbage in (11, 47)\n", printed.getvalue())
            self.assertIn("5/5 cells", printed.getvalue())
            self.assertIn("2 failed", printed.getvalue())
            # A clean run raises nothing.
            build_elevation.run_pool([(8, 47), (10, 47)], {}, Path("."), 2)

            # A dead worker is no cell's failure: the pool is broken, and build_pending starts another round.
            def broken(cell):
                raise build_elevation.BrokenProcessPool("a worker died")

            with patch.object(build_elevation, "_build", broken), self.assertRaises(build_elevation.BrokenProcessPool):
                build_elevation.run_pool(cells, {}, Path("."), 2)

    def test_each_cell_runs_under_a_deadline(self):
        alarms = []
        with patch.object(build_elevation.signal, "alarm", alarms.append), \
                patch.object(build_elevation, "build_cell", side_effect=OSError("offline")), \
                patch.dict(build_elevation._WORKER, chosen={}, out=Path(".")):
            with self.assertRaises(OSError):
                build_elevation._build((8, 47))
        self.assertEqual(alarms, [build_elevation.CELL_DEADLINE, 0])

    def test_a_cell_that_gets_no_answer_names_itself_before_its_worker_ends(self):
        import threading
        import time

        watched = []
        printed = io.StringIO()
        release = threading.Event()

        def slow(cell, chosen, out):
            release.wait(5)

        # The notice comes HANG_NOTICE before the deadline: here after 0.1 s of a 3 s deadline.
        with patch.object(build_elevation, "CELL_DEADLINE", 3), patch.object(build_elevation, "HANG_NOTICE", 2.9), \
                patch.object(build_elevation.signal, "alarm"), \
                patch.object(build_elevation.faulthandler, "dump_traceback_later",
                             lambda timeout, exit: watched.append(("later", round(timeout, 1), exit))), \
                patch.object(build_elevation.faulthandler, "cancel_dump_traceback_later",
                             lambda: watched.append(("cancel",))), \
                patch.object(build_elevation, "build_cell", slow), \
                patch.dict(build_elevation._WORKER, chosen={}, out=Path(".")), patch("sys.stderr", printed):
            worker = threading.Thread(target=build_elevation._build, args=((8, 47),))
            worker.start()
            for _ in range(100):
                if printed.getvalue():
                    break
                time.sleep(0.05)
            release.set()
            worker.join(5)
            said = printed.getvalue()
            # A cell that answers in time says nothing.
            build_elevation._build((9, 47))
            self.assertEqual(printed.getvalue(), said)
        lines = said.splitlines()
        self.assertEqual(lines[0], f"N47E008: no answer for 0.1 s in worker {os.getpid()}; unless it gets one within "
                                   "2.9 s its worker ends, and the cells left are built again")
        # The stack of every thread follows, each line under the cell's name: the call the cell waits in is there.
        self.assertTrue(all(line.startswith("N47E008: ") for line in lines), said)
        self.assertTrue(any(" in slow" in line for line in lines), said)
        self.assertTrue(any(" in _build" in line for line in lines), said)
        # The watchdog would write the stack without a name halfway to the deadline. The notice calls it off, and
        # so does the end of every cell.
        self.assertEqual(watched, [("later", 1.6, False), ("cancel",), ("cancel",), ("later", 1.6, False), ("cancel",)])

    def test_a_cell_is_built_when_the_watchdog_cannot_write_anywhere(self):
        import threading
        import time

        built = []
        before = threading.active_count()
        for error in (ValueError("file doesn't have a fileno"), AttributeError("no stderr"), RuntimeError("unsupported")):
            with self.subTest(error=type(error).__name__), patch.object(build_elevation.signal, "alarm"), \
                    patch.object(build_elevation.faulthandler, "dump_traceback_later", side_effect=error), \
                    patch.object(build_elevation.faulthandler, "cancel_dump_traceback_later") as cancelled, \
                    patch.object(build_elevation, "build_cell", lambda cell, chosen, out: built.append(cell)), \
                    patch.dict(build_elevation._WORKER, chosen={}, out=Path(".")):
                build_elevation._build((8, 47))
                self.assertEqual(cancelled.call_count, 1)
        self.assertEqual(built, [(8, 47)] * 3)
        # No notice is left waiting to speak of a cell that is done.
        for _ in range(100):
            if threading.active_count() == before:
                break
            time.sleep(0.01)
        self.assertEqual(threading.active_count(), before)

    def test_opened_cells_run_under_the_same_deadline(self):
        alarms = []
        opening = build_elevation.Opening(200.0, Path("raw"))
        with patch.object(build_elevation.signal, "alarm", alarms.append), \
                patch.object(build_elevation, "open_cell", side_effect=OSError("disk")) as opened, \
                patch.dict(build_elevation._WORKER, chosen={}, out=Path("."), opening=opening):
            with self.assertRaises(OSError):
                build_elevation._build((8, 47))
        opened.assert_called_once_with((8, 47), {}, Path("."), opening)
        self.assertEqual(alarms, [build_elevation.CELL_DEADLINE, 0])


class ElevationOpeningTests(unittest.TestCase):
    """The production opening, on 41-post tiles so a 3 x 3 mosaic stays small."""

    POSTS = 41
    SOURCE = ElevationReceiptTests.Source("glo30")

    def setUp(self):
        for module in (build_elevation, sample_elevation):
            patcher = patch.object(module, "POSTS", self.POSTS)
            patcher.start()
            self.addCleanup(patcher.stop)

    def random_tiles(self, cells, seed=1):
        """Independent random tiles, so neighbours disagree on the border posts they share."""
        import numpy as np

        rng = np.random.default_rng(seed)
        tiles = {}
        for cell in cells:
            heights = rng.uniform(0, 60, (self.POSTS, self.POSTS)).astype("float32")
            heights[rng.uniform(size=heights.shape) < 0.03] = np.nan
            tiles[cell] = heights
        return tiles

    def write_raw(self, raw, tiles):
        (raw / "receipts").mkdir(parents=True)
        for cell, heights in tiles.items():
            build_elevation.write_receipt(raw, {
                "cell": build_elevation.hgt_name(*cell), "source": "glo30", "url": self.SOURCE.tile_url(*cell),
                "bytes": 1, **build_elevation.write_tile(raw, cell, heights)})
        return {cell: self.SOURCE for cell in tiles}

    def open_in_order(self, raw, out, chosen, cells, radius=100.0):
        (out / "receipts").mkdir(parents=True)
        opening = build_elevation.Opening(radius, raw)
        for cell in cells:
            build_elevation.open_cell(cell, chosen, out, opening)
        return opening

    def test_one_latitude_gives_the_sample_tools_opening(self):
        import numpy as np

        rng = np.random.default_rng(3)
        for latitude in (0, 47, 75):
            heights = rng.uniform(0, 50, (90, 120)).astype("float32")
            heights[rng.uniform(size=heights.shape) < 0.05] = np.nan
            heights[20:40, 30:70] = np.nan
            columns = np.full(90, build_elevation.footprint_columns(100, latitude, 10 ** 6))
            with self.subTest(latitude=latitude):
                np.testing.assert_array_equal(
                    build_elevation.open_posts(heights, build_elevation.footprint_rows(100), columns),
                    sample_elevation.open_heights(heights, 100, latitude))

    def test_runs_reduce_over_every_post_of_each_rows_own_ellipse(self):
        import numpy as np

        def every_post(array, rows, columns, reduce, spread):
            padded = np.pad(array, ((rows, rows), (int(columns.max()),) * 2), mode="edge")
            own = np.pad(columns, rows, mode="edge")
            result = np.empty_like(array)
            for i, j in np.ndindex(array.shape):
                values = []
                for k in range(2 * rows + 1):
                    # Erosion reads the ellipse of post (i, j); dilation takes the
                    # ellipses of the posts k - rows rows above that cover it.
                    row = i + 2 * rows - k if spread else i + k
                    span = build_elevation.ellipse_spans(rows, int(own[row] if spread else columns[i]))[k]
                    centre = j + int(columns.max())
                    values.append(padded[row, centre - span:centre + span + 1])
                result[i, j] = reduce(np.concatenate(values))
            return result

        array = np.random.default_rng(4).uniform(0, 50, (40, 50)).astype("float32")
        columns = np.array([3] * 10 + [4] * 12 + [6] * 8 + [9] * 10)
        expected = (every_post(array, 2, columns, np.min, False), every_post(array, 2, columns, np.max, True))
        for block in (build_elevation.RUN_TABLE_POSTS, 500):
            with self.subTest(block=block), patch.object(build_elevation, "RUN_TABLE_POSTS", block):
                np.testing.assert_array_equal(build_elevation.erode_rows(array, 2, columns), expected[0])
                np.testing.assert_array_equal(build_elevation.dilate_rows(array, 2, columns), expected[1])

    def test_opening_never_raises_a_post_and_keeps_no_data(self):
        import numpy as np

        heights = np.random.default_rng(5).uniform(0, 50, (200, 300)).astype("float32")
        heights[50:80, 100:200] = np.nan
        opened = build_elevation.open_posts(heights, 3, np.repeat(np.arange(3, 23), 10))
        valid = np.isfinite(heights)
        self.assertTrue(np.isnan(opened[~valid]).all())
        self.assertTrue(np.isfinite(opened[valid]).all())
        self.assertTrue((opened[valid] <= heights[valid]).all())

    def test_ellipse_widens_with_latitude_and_stops_at_half_a_cell(self):
        rows = build_elevation.footprint_rows(200)
        self.assertEqual(rows, 6)
        self.assertEqual(build_elevation.ellipse_spans(6, 8), tuple(
            int(count) // 2 for count in sample_elevation.footprint(200, -34.5).sum(axis=1)))
        widths = [build_elevation.footprint_columns(200, latitude, 1799) for latitude in (0, 47, 60, 80, 89.9, 90)]
        self.assertEqual(widths, [6, 9, 13, 37, 1799, 1799])

    def test_border_posts_are_identical_whichever_neighbour_is_opened_first(self):
        import numpy as np

        # At 70-71 degrees the half-width changes from 10 to 9 posts inside each cell.
        cells = [(x, y) for x in range(7, 11) for y in range(69, 72) if (x, y) != (10, 71)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            chosen = self.write_raw(root / "raw", self.random_tiles(cells))
            # (9, 71) has no tile to its east.
            pairs = [((8, 70), (9, 70)), ((8, 70), (8, 71)), ((9, 71), (9, 70))]
            orders = {"first": [cell for pair in pairs for cell in pair],
                      "second": [cell for pair in pairs for cell in reversed(pair)][::-1]}
            for name, order in orders.items():
                self.open_in_order(root / "raw", root / name, chosen, dict.fromkeys(order))
            for cell in dict.fromkeys(orders["first"]):
                path = build_elevation.hgt_path(Path(), *cell)
                self.assertEqual((root / "first" / path).read_bytes(), (root / "second" / path).read_bytes())

            def posts(cell):
                return build_elevation.read_tile(build_elevation.hgt_path(root / "first", *cell))[0]

            np.testing.assert_array_equal(posts((8, 70))[:, -1], posts((9, 70))[:, 0])
            np.testing.assert_array_equal(posts((8, 70))[0], posts((8, 71))[-1])
            np.testing.assert_array_equal(posts((9, 70))[0], posts((9, 71))[-1])
            self.assertFalse(np.array_equal(posts((8, 70)), self.random_tiles(cells)[(8, 70)], equal_nan=True))

    def test_a_cell_opened_alone_equals_its_cut_from_the_opened_mosaic_of_its_neighbourhood(self):
        import numpy as np

        for centre, missing in (((8, 70), None), ((8, 47), (9, 48)), ((179, -20), (-180, -19))):
            longitude, latitude = centre
            neighbourhood = [(centre, 0)] + [build_elevation.neighbour(longitude, latitude, dx, dy)
                                             for dx, dy in build_elevation.NEIGHBOURS]
            tiles = self.random_tiles([cell for cell, _ in neighbourhood if cell != missing], seed=latitude + 90)
            # Unwrap the antimeridian so the mosaic is one array; the southern then eastern tile wins.
            placed = {(cell[0] + shift, cell[1]): tiles[cell] for cell, shift in neighbourhood if cell in tiles}
            order = sorted(placed, key=lambda cell: (-cell[1], cell[0]))
            mosaic, west, north = sample_elevation.mosaic(order, placed.__getitem__)
            rows = build_elevation.footprint_rows(100)
            latitudes = build_elevation.row_latitudes(north, 0, mosaic.shape[0])
            columns = [build_elevation.footprint_columns(100, latitude, (self.POSTS - 1) // 2 - 1)
                       for latitude in latitudes]
            expected = sample_elevation.cut(build_elevation.open_posts(mosaic, rows, columns), west, north, centre)
            with self.subTest(centre=centre):
                np.testing.assert_array_equal(build_elevation.opened_cell(centre, tiles.get, 100), expected)

    def test_opened_receipts_follow_the_raw_tiles_and_the_radius(self):
        import numpy as np

        cells = [(x, y) for x in range(7, 10) for y in range(46, 49)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tiles = self.random_tiles(cells)
            chosen = self.write_raw(root / "raw", tiles)
            opening = self.open_in_order(root / "raw", root / "out", chosen, [(8, 47)])
            receipt = build_elevation.current_opened_receipt(root / "out", (8, 47), chosen, opening)
            self.assertEqual(sorted(receipt["inputTiles"]), sorted(build_elevation.hgt_name(*cell) for cell in cells))
            self.assertEqual(receipt["raw"]["cell"], "N47E008")
            self.assertIsNone(build_elevation.current_opened_receipt(
                root / "out", (8, 47), chosen, build_elevation.Opening(200.0, root / "raw")))
            # A neighbour's raw tile changes: the opened cell is stale and is opened again.
            build_elevation.write_receipt(root / "raw", {
                "cell": "N48E009", "source": "glo30", "url": self.SOURCE.tile_url(9, 48), "bytes": 1,
                **build_elevation.write_tile(root / "raw", (9, 48), np.zeros((self.POSTS,) * 2, dtype="float32"))})
            self.assertIsNone(build_elevation.current_opened_receipt(root / "out", (8, 47), chosen, opening))
            # A raw tile that no longer matches its receipt stops the opening.
            build_elevation.write_tile(root / "raw", (7, 46), tiles[(9, 48)])
            with self.assertRaisesRegex(ValueError, "do not match"):
                build_elevation.open_cell((8, 47), chosen, root / "out", opening)

    def test_opened_tiles_are_never_taken_for_raw_ones(self):
        class Policy:
            version = 2
            sources = [type("S", (), {"id": "glo30", "index_sha256": "i", "terms_url": "t", "attribution_url": "a"})]

        cells = [(x, y) for x in range(7, 10) for y in range(46, 49)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            chosen = self.write_raw(root / "raw", self.random_tiles(cells))
            opening = self.open_in_order(root / "raw", root / "out", chosen, [(8, 47)])
            self.assertIsNotNone(build_elevation.current_opened_receipt(root / "out", (8, 47), chosen, opening))
            # A raw run over the opened directory builds the cell again instead of labelling it raw.
            self.assertIsNone(build_elevation.current_receipt(root / "out", (8, 47), chosen))
            policy_path = root / "policy.json"
            policy_path.write_text("{}")
            with self.assertRaisesRegex(ValueError, "no receipt"):
                build_elevation.write_manifest(root / "out", policy_path, Policy, chosen, [(8, 47)])
            # An opened directory passed as --raw has no raw tiles to open.
            self.assertIsNone(build_elevation.opening_inputs((8, 47), chosen, root / "out"))
            with self.assertRaisesRegex(ValueError, "no current raw tile"):
                build_elevation.open_cell((8, 47), chosen, root / "again", build_elevation.Opening(100.0, root / "out"))

    def test_manifest_records_the_opening_and_the_graph_manifest_carries_it(self):
        class Policy:
            version = 2
            sources = [type("S", (), {"id": "glo30", "index_sha256": "i", "terms_url": "t", "attribution_url": "a"})]

        cells = [(x, y) for x in range(7, 10) for y in range(46, 49)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            chosen = self.write_raw(root / "raw", self.random_tiles(cells))
            policy_path = root / "policy.json"
            policy_path.write_text("{}")
            raw_manifest = build_elevation.write_manifest(root / "raw", policy_path, Policy, chosen, cells, [6, 45, 10, 49])
            opening = self.open_in_order(root / "raw", root / "out", chosen, [(8, 47)])
            manifest = json.loads(build_elevation.write_manifest(
                root / "out", policy_path, Policy, chosen, [(8, 47)], [8, 47, 9, 48], opening).read_text())
            self.assertIsNone(json.loads(raw_manifest.read_text())["method"])
            method = manifest["method"]
            self.assertEqual((method["name"], method["radiusMetres"], method["footprintLatitude"]),
                             ("grey-opening", 100.0, "post row"))
            self.assertEqual(method["input"]["manifestSha256"], hashlib.sha256(raw_manifest.read_bytes()).hexdigest())
            self.assertEqual(elevation_identity(root / "out", sample=True)["method"], method)
            self.assertIsNone(elevation_identity(root / "raw", sample=True)["method"])

    def test_bounded_runs_build_the_raw_tiles_of_every_neighbour(self):
        chosen = {cell: self.SOURCE for cell in [(8, 47), (9, 47), (9, 48), (179, 0), (-180, 1), (5, 5)]}
        self.assertEqual(build_elevation.with_neighbours([(8, 47)], chosen), [(8, 47), (9, 47), (9, 48)])
        self.assertEqual(build_elevation.with_neighbours([(179, 0)], chosen), [(-180, 1), (179, 0)])

    def test_raw_and_opened_tiles_need_separate_directories(self):
        for arguments in (["--opening-radius", "200"], ["--raw", "raw"],
                          ["--opening-radius", "5", "--raw", "raw"], ["--opening-radius", "200", "--raw", "out/raw"],
                          ["--opening-radius", "200", "--raw", "."]):
            argv = ["build_elevation.py", "--policy", "missing.json", "--out", "out", *arguments]
            with self.subTest(arguments=arguments), patch("sys.argv", argv), \
                    patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                build_elevation.main()


class ElevationHybridTests(ElevationOpeningTests):
    """Terrain tiles over opened tiles, on the opening tests' 41-post cells."""

    BAND = 6

    class Policy:
        version = 2
        sources = [type("S", (), {"id": "glo30", "index_sha256": "i", "terms_url": "t", "attribution_url": "a"})]

    def terrain_source(self, cells):
        tiles = {cell: (f"n{cell[1] + 1:02d}w{-cell[0]:03d}", "20260101", 7, "0" * 32) for cell in cells}
        return build_elevation.TerrainSource("usgs-3dep-13", "https://terrain.example", tiles, "c" * 64,
                                             "https://terms.example", "https://credit.example", self.AREA, "a" * 64)

    AREA = Path("area.geojson.gz")

    @staticmethod
    def terrain(*sources):
        """The sources over every cell one of them has a tile for."""
        return build_elevation.Terrain.over(sources, sorted({cell for source in sources for cell in source.tiles}))

    def write_terrain(self, directory, source, tiles):
        import numpy as np

        (directory / "receipts").mkdir(parents=True)
        for cell, heights in tiles.items():
            part = {**source.pin(cell), "readBytes": 7, "outsidePosts": 0, "posts": int(np.isfinite(heights).sum())}
            build_elevation.write_receipt(directory, {
                "cell": build_elevation.hgt_name(*cell), "sources": [part], "bytes": 7, "outsidePosts": 0,
                **build_elevation.write_tile(directory, cell, heights)})

    def hybrid_setup(self, root, cells, terrain_tiles):
        """Opened tiles of `cells` and terrain tiles; returns chosen and the Hybrid."""
        chosen = self.write_raw(root / "raw", self.random_tiles(cells))
        opening = self.open_in_order(root / "raw", root / "opened", chosen, cells)
        source = self.terrain_source(terrain_tiles)
        self.write_terrain(root / "terrain", source, terrain_tiles)
        (root / "out" / "receipts").mkdir(parents=True)
        return chosen, build_elevation.Hybrid(self.terrain(source), root / "terrain", root / "opened", opening,
                                              self.BAND)

    def test_the_fill_is_lifted_to_the_terrain_and_fades_out(self):
        import numpy as np

        terrain = np.full((9, 30), np.nan, dtype="float32")
        terrain[:, :10] = 10
        fill = np.full((9, 30), 4, dtype="float32")
        fill[4, 3] = np.nan       # under the terrain: the terrain post stays
        fill[2, 20] = np.nan      # beyond it: no data stays no data
        heights, known, blended = build_elevation.blend_fill(terrain, fill, 8)
        np.testing.assert_array_equal(heights[:, :10], 10)
        self.assertEqual((int(known.sum()), int(blended.sum())), (90, 9 * 8))
        # Steps 1 to 8 beyond the edge carry 6 m with weights 8/9 down to 1/9; then the fill alone.
        np.testing.assert_allclose(heights[0, 10:18], 4 + 6 * np.arange(8, 0, -1) / 9, rtol=1e-6)
        np.testing.assert_array_equal(heights[0, 18:], 4)
        self.assertTrue(np.isnan(heights[2, 20]) and not blended[2, 20])
        # Row 4's terrain post at the edge carries nothing. The rows beside it lift the row a step late,
        # at weights 7/9, 6/9, ... in place of 8/9, 7/9, ...; it is not left at the fill's height.
        fill[4, 3], fill[4, 9] = 4, np.nan
        heights = build_elevation.blend_fill(terrain, fill, 8)[0]
        np.testing.assert_allclose(heights[4, 10:13], 4 + 6 * np.array([7, 6, 5]) / 9, rtol=1e-6)
        np.testing.assert_allclose(heights[3, 10:13], 4 + 6 * np.array([8, 7, 6]) / 9, rtol=1e-6)
        # Nothing to meet: the fill unchanged; nothing to fill: the terrain unchanged.
        np.testing.assert_array_equal(build_elevation.blend_fill(np.full_like(fill, np.nan), fill, 8)[0], fill)
        np.testing.assert_array_equal(build_elevation.blend_fill(fill * 0 + 7, fill, 8)[0][0], 7)

    def test_a_ragged_edge_is_carried_as_the_mean_of_the_nearer_posts(self):
        import numpy as np

        rng = np.random.default_rng(5)
        terrain = rng.uniform(0, 40, (60, 60)).astype("float32")
        terrain[rng.uniform(size=terrain.shape) < 0.5] = np.nan
        terrain[20:45, 15:50] = np.nan
        fill = rng.uniform(0, 40, (60, 60)).astype("float32")
        heights, known, blended = build_elevation.blend_fill(terrain, fill, 5)
        np.testing.assert_array_equal(heights[known], terrain[known])
        self.assertFalse((known & blended).any())
        far = np.zeros_like(known)
        far[27:38, 22:43] = True  # more than five steps from any terrain post
        np.testing.assert_array_equal(heights[far], fill[far])
        # A post between two terrain posts takes the mean of their differences at weight 5/6.
        terrain = np.array([[8, np.nan, 2]], dtype="float32")
        fill = np.array([[5, 1, 5]], dtype="float32")
        self.assertAlmostEqual(float(build_elevation.blend_fill(terrain, fill, 5)[0][0, 1]), 1 + 5 / 6 * 0, places=6)
        # A window with a margin of the band gives every post the whole array's value.
        terrain = rng.uniform(0, 40, (60, 60)).astype("float32")
        terrain[:, 30:] = np.nan
        terrain[rng.uniform(size=terrain.shape) < 0.2] = np.nan
        fill = rng.uniform(0, 40, (60, 60)).astype("float32")
        whole = build_elevation.blend_fill(terrain, fill, 5)[0]
        part = build_elevation.blend_fill(terrain[10:50, 15:55], fill[10:50, 15:55], 5)[0]
        np.testing.assert_array_equal(part[5:-5, 5:-5], whole[15:45, 20:50])

    def test_a_blended_cell_equals_its_cut_from_the_blend_of_its_neighbourhood(self):
        import numpy as np

        centre = (-84, 42)
        cells = [(x, y) for x in range(-86, -81) for y in range(40, 45)]
        ring = [(x, y) for x in range(-85, -82) for y in range(41, 44)]
        rng = np.random.default_rng(9)
        # The terrain covers the centre's west and its western neighbours, with holes; nothing to the east.
        terrain_tiles = {}
        for cell in ring:
            if cell[0] > -84:
                continue
            heights = rng.uniform(100, 160, (self.POSTS, self.POSTS)).astype("float32")
            heights[rng.uniform(size=heights.shape) < 0.1] = np.nan
            if cell == centre:
                heights[:, 25:] = np.nan
            terrain_tiles[cell] = heights
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            chosen = self.write_raw(root / "raw", self.random_tiles(cells))
            opening = self.open_in_order(root / "raw", root / "opened", chosen, cells)
            source = self.terrain_source(terrain_tiles)
            self.write_terrain(root / "terrain", source, terrain_tiles)
            (root / "out" / "receipts").mkdir(parents=True)
            hybrid = build_elevation.Hybrid(self.terrain(source), root / "terrain", root / "opened", opening,
                                            self.BAND)
            receipt = build_elevation.hybrid_cell(centre, chosen, root / "out", hybrid)

            def stored(directory, cell):
                return build_elevation.read_tile(build_elevation.hgt_path(directory, *cell))[0]

            # As in a window: the southern then the eastern tile wins a shared border post, with or without data.
            order = sorted(ring, key=lambda cell: (-cell[1], cell[0]))
            opened, west, north = sample_elevation.mosaic(order, lambda cell: stored(root / "opened", cell))
            terrain = np.full_like(opened, np.nan)
            for cell in order:
                if cell in terrain_tiles:
                    row, column = (north - 1 - cell[1]) * (self.POSTS - 1), (cell[0] - west) * (self.POSTS - 1)
                    terrain[row:row + self.POSTS, column:column + self.POSTS] = stored(root / "terrain", cell)
            expected = sample_elevation.cut(build_elevation.blend_fill(terrain, opened, self.BAND)[0], west, north,
                                            centre)
            payload, _ = build_elevation.encode_posts(expected)
            self.assertEqual(receipt["hgtSha256"], hashlib.sha256(payload).hexdigest())
            self.assertGreater(receipt["terrainPosts"], 500)
            self.assertGreater(receipt["blendedPosts"], 100)
            self.assertEqual(sorted(receipt["inputTiles"]["terrain"]),
                             sorted(build_elevation.hgt_name(*cell) for cell in terrain_tiles))
            self.assertEqual(len(receipt["inputTiles"]["opened"]), 9)
            # The cells beside the centre get the same posts on the borders they share with it.
            for cell in ((-83, 42), (-85, 42), (-84, 43)):
                build_elevation.hybrid_cell(cell, chosen, root / "out", hybrid)
            np.testing.assert_array_equal(stored(root / "out", centre)[:, -1], stored(root / "out", (-83, 42))[:, 0])
            np.testing.assert_array_equal(stored(root / "out", centre)[:, 0], stored(root / "out", (-85, 42))[:, -1])
            np.testing.assert_array_equal(stored(root / "out", centre)[0], stored(root / "out", (-84, 43))[-1])

    def test_cells_away_from_the_terrain_are_their_opened_tiles(self):
        cells = [(x, y) for x in range(-86, -81) for y in range(40, 45)]
        ring = [(x, y) for x in range(-85, -82) for y in range(41, 44)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            chosen = self.write_raw(root / "raw", self.random_tiles(cells))
            opening = self.open_in_order(root / "raw", root / "opened", chosen, ring)
            source = self.terrain_source({})
            self.write_terrain(root / "terrain", source, {})
            (root / "out" / "receipts").mkdir(parents=True)
            hybrid = build_elevation.Hybrid(self.terrain(source), root / "terrain", root / "opened", opening,
                                            self.BAND)
            receipt = build_elevation.hybrid_cell((-84, 42), chosen, root / "out", hybrid)
            path = build_elevation.hgt_path(Path(), -84, 42)
            self.assertEqual((root / "out" / path).read_bytes(), (root / "opened" / path).read_bytes())
            self.assertEqual(receipt["inputTiles"], {"opened": {"N42W084": receipt["hgtSha256"]}, "terrain": {}})
            self.assertEqual((receipt["terrainPosts"], receipt["blendedPosts"]), (0, 0))
            self.assertIsNotNone(build_elevation.current_hybrid_receipt(root / "out", (-84, 42), chosen, hybrid))

    def test_blended_receipts_follow_their_tiles_and_the_manifest_names_both_sources(self):
        import numpy as np

        cells = [(x, y) for x in range(-86, -81) for y in range(40, 45)]
        west = np.full((self.POSTS,) * 2, 120, dtype="float32")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            chosen = self.write_raw(root / "raw", self.random_tiles(cells))
            opening = self.open_in_order(root / "raw", root / "opened", chosen, cells)
            source = self.terrain_source({(-85, 42): west})
            self.write_terrain(root / "terrain", source, {(-85, 42): west})
            (root / "out" / "receipts").mkdir(parents=True)
            hybrid = build_elevation.Hybrid(self.terrain(source), root / "terrain", root / "opened", opening,
                                            self.BAND)
            policy_path = root / "policy.json"
            policy_path.write_text("{}")
            list_path = root / "elevation-sources.json"
            list_path.write_text("{}")
            build_elevation.write_manifest(root / "raw", policy_path, self.Policy, chosen, cells, [-87, 39, -80, 46])
            build_elevation.write_manifest(root / "opened", policy_path, self.Policy, chosen, cells,
                                           [-86, 40, -81, 45], opening)
            terrain_manifest = build_elevation.write_terrain_manifest(root / "terrain", list_path, hybrid.terrain,
                                                                      [(-85, 42)], [-86, 40, -81, 45])
            listed = json.loads(terrain_manifest.read_text())
            self.assertEqual((listed["catalogCells"], listed["cells"], listed["sourceBytes"]), (1, 1, 7))
            self.assertEqual(listed["sources"], [{**source.identity(), "cells": 1, "posts": self.POSTS ** 2,
                                                  "rejectedPixels": 0}])
            self.assertEqual(listed["rejectedPixels"], 0)
            for cell in [(-85, 42), (-84, 42)]:
                build_elevation.hybrid_cell(cell, chosen, root / "out", hybrid)
            manifest = json.loads(build_elevation.write_manifest(
                root / "out", policy_path, self.Policy, chosen, [(-85, 42), (-84, 42)], [-85, 42, -83, 43], opening,
                hybrid).read_text())
            method = manifest["method"]
            self.assertEqual((method["name"], method["terrain"], method["blendPosts"], method["fill"]["name"]),
                             ("terrain-over-opening", ["usgs-3dep-13"], self.BAND, "grey-opening"))
            self.assertEqual(method["inputs"]["terrain"]["manifestSha256"],
                             hashlib.sha256(terrain_manifest.read_bytes()).hexdigest())
            # The source gave its posts to one terrain tile of these cells.
            self.assertEqual([(s["id"], s["cells"]) for s in manifest["sources"]], [("glo30", 2), ("usgs-3dep-13", 1)])
            self.assertEqual(manifest["sources"][1], {**source.identity(), "cells": 1, "posts": self.POSTS ** 2,
                                                      "rejectedPixels": 0})
            # The eastern cell has no tile of its own, but the border column it shares with the western one.
            self.assertEqual((manifest["terrain"]["cells"], manifest["terrain"]["posts"]),
                             (2, self.POSTS ** 2 + self.POSTS))
            # The eastern cell's posts within the band of that column are lifted, bar the few without data.
            blended = manifest["terrain"]["blendedPosts"]
            self.assertTrue(self.POSTS * (self.BAND - 1) <= blended <= self.POSTS * self.BAND, blended)
            # Opened tiles name no terrain.
            self.assertNotIn("terrain", json.loads((root / "opened" / "elevation-manifest.json").read_text()))
            identity = elevation_identity(root / "out", sample=True)
            self.assertEqual((identity["sources"], identity["method"]), (["glo30", "usgs-3dep-13"], method))
            # A graph graded with it must mark every bridge; opened or raw tiles alone need not.
            self.assertTrue(needs_all_bridges(identity))
            self.assertFalse(needs_all_bridges(elevation_identity(root / "opened", sample=True)))
            self.assertFalse(needs_all_bridges(elevation_identity(root / "raw", sample=True)))
            self.assertFalse(needs_all_bridges(None))
            # The terrain tiles alone are not an elevation set a graph may be graded with.
            (root / "terrain" / "elevation-manifest.json").write_bytes(terrain_manifest.read_bytes())
            with self.assertRaisesRegex(ValueError, "Not a Valhalla elevation manifest"):
                elevation_identity(root / "terrain", sample=True)
            # A changed terrain tile, another band or a missing opened neighbour makes the receipt stale.
            self.assertIsNotNone(build_elevation.current_hybrid_receipt(root / "out", (-84, 42), chosen, hybrid))
            self.assertIsNone(build_elevation.current_hybrid_receipt(
                root / "out", (-84, 42), chosen,
                build_elevation.Hybrid(hybrid.terrain, hybrid.tiles, hybrid.opened, opening, 3)))
            self.write_terrain(root / "terrain2", source, {(-85, 42): west + 1})
            moved = build_elevation.Hybrid(hybrid.terrain, root / "terrain2", hybrid.opened, opening, self.BAND)
            self.assertIsNone(build_elevation.current_hybrid_receipt(root / "out", (-84, 42), chosen, moved))
            build_elevation.write_tile(root / "terrain", (-85, 42), west + 2)
            with self.assertRaisesRegex(ValueError, "do not match"):
                build_elevation.hybrid_cell((-84, 42), chosen, root / "out", hybrid)
            (root / "opened" / "receipts" / "N43W084.json").unlink()
            self.assertIsNone(build_elevation.hybrid_inputs((-84, 42), chosen, hybrid))
            with self.assertRaisesRegex(ValueError, "no current opened or terrain tile"):
                build_elevation.hybrid_cell((-84, 42), chosen, root / "out", hybrid)

    def test_terrain_and_blend_stages_run_under_a_deadline(self):
        source = self.terrain_source({})
        hybrid = build_elevation.Hybrid(self.terrain(source), Path("terrain"), Path("opened"),
                                        build_elevation.Opening(400.0, Path("raw")))
        # A terrain tile is twenty times a Copernicus cell, so its download gets longer. A cell that reads a
        # part of one object downloads no tile and keeps the cell deadline.
        self.assertGreater(build_elevation.TERRAIN_DEADLINE, build_elevation.CELL_DEADLINE)
        tiled = self.terrain_source([(-84, 42)])
        ranged = build_elevation.TerrainSource(
            "nrcan-mrdem-30", build_elevation.MRDEM_URL, {(-84, 42): None, (-80, 44): None}, "c" * 64,
            "https://terms.example", "https://credit.example", self.AREA, "a" * 64, build_elevation.MRDEM_ADAPTER,
            (83854027098, "1b" * 16 + "-9997"))
        terrain = {(-84, 42): (tiled, ranged), (-80, 44): (ranged,)}
        for stage, function, cell, deadline in (
                (build_elevation.TERRAIN, "build_terrain_cell", (-84, 42), build_elevation.TERRAIN_DEADLINE),
                (build_elevation.TERRAIN, "build_terrain_cell", (-80, 44), build_elevation.CELL_DEADLINE),
                (hybrid, "hybrid_cell", (-84, 42), build_elevation.CELL_DEADLINE)):
            alarms = []
            chosen = terrain if stage == build_elevation.TERRAIN else {}
            with self.subTest(function=function, cell=cell), patch.object(build_elevation.signal, "alarm", alarms.append), \
                    patch.object(build_elevation, function, side_effect=OSError("offline")) as called, \
                    patch.dict(build_elevation._WORKER, chosen=chosen, out=Path("."), opening=None, stage=stage):
                with self.assertRaises(OSError):
                    build_elevation._build(cell)
                self.assertEqual(called.call_count, 1)
                self.assertEqual(alarms, [deadline, 0])

    def test_a_connection_that_drops_in_the_middle_of_a_body_is_retried(self):
        import http.client

        class Response:
            status = 206
            headers = {"Content-Range": "bytes 4-7/20", "ETag": '"abc"', "Content-Length": "4"}

            def __init__(self, failure):
                self.failure = failure

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                if self.failure:
                    raise self.failure
                return b"data"

        for failure in (http.client.IncompleteRead(b"da", 2), ConnectionResetError("reset"), TimeoutError("slow")):
            answers = [Response(failure), Response(None)]
            asked = []

            def urlopen(request, timeout):
                asked.append(request.get_header("Range") if hasattr(request, "get_header") else request)
                return answers.pop(0)

            with self.subTest(failure=type(failure).__name__), \
                    patch.object(build_elevation.urllib.request, "urlopen", urlopen), \
                    patch.object(build_elevation.time, "sleep") as slept:
                self.assertEqual(build_elevation.fetch_range("https://u/t.tif", 4, 8), (b"data", 20, "abc"))
                self.assertEqual(asked, ["bytes=4-7", "bytes=4-7"])
                self.assertEqual(slept.call_count, 1)
                # The whole-file download of a Copernicus cell retries the same failures.
                answers[:] = [Response(failure), Response(None)]
                self.assertEqual(build_elevation.fetch("https://u/c.tif"), (b"data", "abc"))
        with patch.object(build_elevation.urllib.request, "urlopen",
                          lambda request, timeout: Response(http.client.IncompleteRead(b"", 4))), \
                patch.object(build_elevation.time, "sleep"), self.assertRaises(http.client.IncompleteRead):
            build_elevation.fetch_range("https://u/t.tif", 4, 8, attempts=2)

    def terrain_tile(self, cell, pixels, crs="EPSG:4269", shift=0):
        """A GeoTIFF laid out as the cell's 3DEP tile, at the tests' 41 posts."""
        from affine import Affine
        from rasterio.io import MemoryFile

        fine = build_elevation.STEP / 3
        memory = MemoryFile()
        with memory.open(driver="GTiff", width=pixels.shape[1], height=pixels.shape[0], count=1, dtype="float32",
                         crs=crs, nodata=-999999,
                         transform=Affine(fine, 0, cell[0] - 6 * fine + shift, 0, -fine, cell[1] + 1 + 6 * fine)) as dataset:
            dataset.write(pixels, 1)
        return memory

    def test_a_3dep_tile_gives_its_cells_posts_and_no_other_tile_passes(self):
        import numpy as np
        import rasterio

        side = (self.POSTS - 1) * 3 + 12
        rows, columns = np.mgrid[0:side, 0:side]
        pixels = (200 + 0.1 * (rows + 0.5) + 0.2 * (columns + 0.5)).astype("float32")
        pixels[90:] = -999999
        cell = (-74, 40)
        with self.terrain_tile(cell, pixels) as memory, memory.open() as dataset, rasterio.Env():
            posts, invalid = build_elevation.terrain_posts(dataset, cell)
            for other in ((-73, 40), (-74, 41)):
                with self.assertRaisesRegex(ValueError, "not the 3DEP"):
                    build_elevation.terrain_posts(dataset, other)
        self.assertEqual((posts.shape, invalid), ((self.POSTS,) * 2, (side - 90) * side))
        post_rows, post_columns = np.mgrid[0:27, 0:self.POSTS]
        np.testing.assert_allclose(posts[:27], 200 + 0.1 * (6 + 3 * post_rows) + 0.2 * (6 + 3 * post_columns), atol=1e-3)
        self.assertTrue(np.isnan(posts[30:]).all())
        for tile in (self.terrain_tile(cell, pixels, crs="EPSG:4326"), self.terrain_tile(cell, pixels[:, :-3]),
                     self.terrain_tile(cell, pixels, shift=build_elevation.STEP / 6)):
            with tile as memory, memory.open() as dataset, self.assertRaisesRegex(ValueError, "not the 3DEP"):
                build_elevation.terrain_posts(dataset, cell)
        pixels[0, 0] = 9000
        with self.terrain_tile(cell, pixels) as memory, memory.open() as dataset, \
                self.assertRaisesRegex(ValueError, "lie outside"):
            build_elevation.terrain_posts(dataset, cell)

    def test_a_tile_is_downloaded_in_ranges_checked_and_removed(self):
        import numpy as np

        side = (self.POSTS - 1) * 3 + 12
        cell = (-74, 40)
        with self.terrain_tile(cell, np.full((side, side), 31.4, dtype="float32")) as memory:
            data = memory.read()
        etag = hashlib.md5(data).hexdigest()
        requests = []

        def fetch_range(url, start, end):
            requests.append((url, start, end))
            return data[start:end], len(data), etag

        with tempfile.TemporaryDirectory() as tmp, patch.object(build_elevation, "fetch_range", fetch_range), \
                patch.object(build_elevation, "FETCH_PART", 1000):
            out = Path(tmp)
            (out / "receipts").mkdir()
            self.assertEqual(build_elevation.fetch_to_file("https://u/t.tif", out / "t.tif", len(data)),
                             (hashlib.sha256(data).hexdigest(), etag))
            self.assertEqual((out / "t.tif").read_bytes(), data)
            self.assertEqual(sorted(requests)[1], ("https://u/t.tif", 1000, 2000))
            self.assertEqual(sum(end - start for _, start, end in requests), len(data))
            with self.assertRaisesRegex(ValueError, "not the catalog's"):
                build_elevation.fetch_to_file("https://u/t.tif", out / "short.tif", len(data) - 1)
            # A part that fails for good stops the download: the parts after it are never asked for.
            requests.clear()

            def failing(url, start, end):
                requests.append(start)
                if start == 1000:
                    raise OSError("gone")
                return data[start:end], len(data), etag

            with patch.object(build_elevation, "fetch_range", failing), self.assertRaisesRegex(OSError, "gone"):
                build_elevation.fetch_to_file("https://u/t.tif", out / "gone.tif", len(data), connections=1)
            self.assertEqual(requests, [0, 1000])
            # The area holds the western half of the cell's 41 posts: its edge runs between two post columns.
            half = (self.POSTS - 1) // 2
            edge = -74 + (half + 0.5) * build_elevation.STEP
            area = self.write_area(out / "area.geojson.gz", [(-74.5, 39.5), (edge, 39.5), (edge, 41.5), (-74.5, 41.5)])
            source = build_elevation.TerrainSource(
                "usgs-3dep-13", "https://terrain.example", {cell: ("n41w074", "20260917", len(data), etag)},
                "c" * 64, "https://terms.example", "https://credit.example", *area)
            receipt = build_elevation.build_terrain_cell(cell, {cell: (source,)}, out)
            part, = receipt["sources"]
            self.assertEqual((part["source"], part["url"], part["bytes"], part["sha256"], part["tileDate"]),
                             ("usgs-3dep-13", "https://terrain.example/n41w074/USGS_13_n41w074_20260917.tif",
                              len(data), hashlib.sha256(data).hexdigest(), "20260917"))
            self.assertEqual(build_elevation.current_terrain_receipt(out, cell, {cell: (source,)}), receipt)
            # A 3DEP tile's receipt from before receipts named a rule for dropping pixels is still current.
            self.assertIsNone(part["rejects"])
            earlier = json.loads(json.dumps(receipt))
            del earlier["sources"][0]["rejects"]
            build_elevation.write_receipt(out, earlier)
            self.assertEqual(build_elevation.current_terrain_receipt(out, cell, {cell: (source,)}), earlier)
            build_elevation.write_receipt(out, receipt)
            posts = build_elevation.read_tile(build_elevation.hgt_path(out, *cell))[0]
            np.testing.assert_array_equal(posts[:, :half + 1], 31)
            self.assertTrue(np.isnan(posts[:, half + 1:]).all())
            self.assertEqual((receipt["outsidePosts"], part["outsidePosts"], part["areaSha256"], part["posts"]),
                             (self.POSTS * half, self.POSTS * half, area[1], self.POSTS * (half + 1)))
            self.assertEqual((receipt["bytes"], receipt["noDataPosts"]), (len(data), self.POSTS * half))
            self.assertEqual(list((out / "downloads").iterdir()), [])
            # Another area makes the tile stale: it was cut to the old one. So does another dated tile.
            moved = build_elevation.TerrainSource(
                "usgs-3dep-13", "https://terrain.example", source.tiles, "c" * 64, "https://terms.example",
                "https://credit.example", area[0], "b" * 64)
            self.assertIsNone(build_elevation.current_terrain_receipt(out, cell, {cell: (moved,)}))
            newer = build_elevation.TerrainSource(
                "usgs-3dep-13", "https://terrain.example", {cell: ("n41w074", "20261001", len(data), etag)},
                "c" * 64, "https://terms.example", "https://credit.example", *area)
            self.assertIsNone(build_elevation.current_terrain_receipt(out, cell, {cell: (newer,)}))
            # A tile the USGS has replaced since the catalog was written stops the cell.
            stale = build_elevation.TerrainSource(
                "usgs-3dep-13", "https://terrain.example", {cell: ("n41w074", "20260917", len(data), "f" * 32)},
                "c" * 64, "https://terms.example", "https://credit.example", *area)
            with self.assertRaisesRegex(ValueError, "not the catalog's"):
                build_elevation.build_terrain_cell(cell, {cell: (stale,)}, out)
            self.assertEqual(list((out / "downloads").iterdir()), [])

    def mrdem_raster(self, cell, crs="EPSG:3979", pixel=30.0, nodata=-32767.0, side=120, shift=0):
        """A GeoTIFF laid out as MRDEM-30 around the tests' 41 posts of the cell, its heights a plane on the grid.

        Returns the file and a function giving the plane's height at longitudes and latitudes.
        """
        import numpy as np
        from affine import Affine
        from rasterio.io import MemoryFile
        from rasterio.warp import transform

        half = (self.POSTS - 1) / 2 * build_elevation.STEP
        (x,), (y,) = transform("EPSG:4617", "EPSG:3979", [cell[0] + half], [cell[1] + 1 - half])
        left, top = pixel * (round(x / pixel) - side // 2) + shift, pixel * (round(y / pixel) + side // 2)

        def plane(xs, ys):
            return 100 + 0.01 * (np.asarray(xs) - left) + 0.02 * (top - np.asarray(ys))

        rows, columns = np.mgrid[0:side, 0:side]
        pixels = plane(left + (columns + 0.5) * pixel, top - (rows + 0.5) * pixel).astype("float32")
        memory = MemoryFile()
        with memory.open(driver="GTiff", width=side, height=side, count=1, dtype="float32", crs=crs, nodata=nodata,
                         transform=Affine(pixel, 0, left, 0, -pixel, top)) as dataset:
            dataset.write(pixels, 1)

        def height(longitudes, latitudes):
            xs, ys = transform("EPSG:4617", "EPSG:3979", list(longitudes), list(latitudes))
            return plane(xs, ys)

        return memory, height

    def post_positions(self, cell):
        import numpy as np

        rows, columns = np.mgrid[0:self.POSTS, 0:self.POSTS]
        return (cell[0] + columns * build_elevation.STEP).ravel(), (cell[1] + 1 - rows * build_elevation.STEP).ravel()

    def test_the_mrdem_raster_gives_a_cells_posts_and_no_other_raster_passes(self):
        import numpy as np
        import rasterio

        cell = (-80, 43)
        memory, height = self.mrdem_raster(cell)
        with memory, memory.open() as dataset, rasterio.Env():
            posts, window, read = build_elevation.mrdem_posts(dataset, cell)
            pixels = dataset.read(1, window=window)
            # A cell the raster does not reach reads nothing and has no posts.
            empty = build_elevation.mrdem_posts(dataset, (-60, 50))
        self.assertEqual(posts.shape, (self.POSTS,) * 2)
        self.assertEqual(read, {"sha256": hashlib.sha256(pixels.tobytes()).hexdigest(), "invalidPixels": 0,
                                "rejectedPixels": 0, "rejectedHeights": None})
        # The window holds the posts with a margin, and not the whole raster.
        self.assertTrue(45 <= window.width < 120 and 45 <= window.height < 120, window)
        # Bilinear means of a plane are the plane; the warp places a post within an eighth of a pixel.
        np.testing.assert_allclose(posts.ravel(), height(*self.post_positions(cell)), atol=0.12)
        self.assertTrue(np.isnan(empty[0]).all())
        self.assertEqual(empty[1:], (None, {"sha256": hashlib.sha256(b"").hexdigest(), "invalidPixels": 0,
                                            "rejectedPixels": 0, "rejectedHeights": None}))
        for raster in (self.mrdem_raster(cell, crs="EPSG:3978"), self.mrdem_raster(cell, pixel=20.0),
                       self.mrdem_raster(cell, nodata=-9999.0)):
            with raster[0] as other, other.open() as dataset, self.assertRaisesRegex(ValueError, "not the MRDEM-30"):
                build_elevation.mrdem_posts(dataset, cell)

    def test_mrdem_pixels_without_data_and_pixels_that_are_not_ground(self):
        import numpy as np
        import rasterio
        from rasterio.io import MemoryFile

        cell = (-80, 43)
        memory, _ = self.mrdem_raster(cell)
        with memory, memory.open() as dataset:
            profile, pixels = dataset.profile, dataset.read(1)

        def posts_of(changed):
            with MemoryFile() as file:
                with file.open(**profile) as dataset:
                    dataset.write(changed, 1)
                with file.open() as dataset, rasterio.Env():
                    return build_elevation.mrdem_posts(dataset, cell)

        holed = pixels.copy()
        holed[:, 60:] = -32767
        posts, window, read = posts_of(holed)
        self.assertEqual(read["invalidPixels"], window.height * (window.col_off + window.width - 60))
        self.assertEqual((read["rejectedPixels"], read["rejectedHeights"]), (0, None))
        # The raster's east has no data: the eastern posts have none, the western ones all of it.
        self.assertTrue(np.isfinite(posts[:, :5]).all() and np.isnan(posts[:, -5:]).all())

        # A pit as at Holberg Inlet: the raster is pinned, so its garbage is dropped and the cell is built.
        clean, window, _ = posts_of(pixels.copy())
        margin = build_elevation.MRDEM_REJECT_MARGIN
        pitted = pixels.copy()
        pitted[58:61, 57:62] = -694.5    # cannot be ground
        pitted[57, 57:62] = -9.0         # the pit's wall: in range, and within the margin of the pit
        pitted[72, 60] = -9.0            # low and alone: ground, for all the reader knows
        corner = (window.row_off + 2, window.col_off + 2)
        pitted[corner] = 9000.0          # a spike in the window's corner, beyond every post
        posts, again, read = posts_of(pitted)
        self.assertEqual(again, window)
        self.assertEqual(read["rejectedHeights"], [-694.5, 9000.0])
        # The pit with its margin on every side, and the spike with its margin as far as the window reaches.
        self.assertEqual(read["rejectedPixels"], (3 + 2 * margin) * (5 + 2 * margin) + (3 + margin) ** 2)
        self.assertEqual(read["invalidPixels"], 0)
        # The posts over the pit have no data, and no post is lower than the low pixel that was kept.
        dropped = np.isnan(posts)
        self.assertTrue(100 < int(dropped.sum()) < 300, int(dropped.sum()))
        self.assertGreaterEqual(float(np.nanmin(posts)), -9.01)
        self.assertLess(float(np.nanmin(posts)), float(np.nanmin(clean)) - 50)
        # Away from the pit and the low pixel every post is what it was.
        np.testing.assert_allclose(posts[:4], clean[:4], atol=1e-3)
        changed = ~dropped & (np.abs(posts - clean) > 1e-3)
        self.assertTrue(0 < int(changed.sum()) < 150, int(changed.sum()))

    def test_a_pit_beyond_the_posts_still_has_its_wall_dropped_under_them(self):
        import numpy as np
        import rasterio
        from rasterio.io import MemoryFile
        from rasterio.warp import transform

        cell = (-80, 43)
        margin = build_elevation.MRDEM_REJECT_MARGIN
        memory, _ = self.mrdem_raster(cell)
        with memory, memory.open() as dataset:
            profile, pixels = dataset.profile, dataset.read(1)
            # The pixel under the posts' north-east corner, where a neighbouring cell's posts begin.
            longitudes, latitudes = self.post_positions(cell)
            (x,), (y,) = transform("EPSG:4617", dataset.crs, [float(longitudes.max())], [float(latitudes.max())])
            row, column = dataset.index(x, y)

        def posts_of(changed):
            with MemoryFile() as file:
                with file.open(**profile) as dataset:
                    dataset.write(changed, 1)
                with file.open() as dataset, rasterio.Env():
                    return build_elevation.mrdem_posts(dataset, cell)

        clean, window, _ = posts_of(pixels.copy())
        # The window reaches the rule's margin beyond what the resampling alone needs.
        self.assertGreaterEqual(window.col_off + window.width - 1 - column, 2 + margin)
        self.assertGreaterEqual(row - window.row_off, 2 + margin)
        pitted = pixels.copy()
        pitted[row - 1:row + 2, column + margin] = -300.0        # a pit the posts do not reach
        pitted[row - 1:row + 2, column:column + margin] = -9.0   # its wall, as far as the pixel under the post
        posts, _, read = posts_of(pitted)
        self.assertEqual(read["rejectedHeights"], [-300.0, -300.0])
        self.assertGreater(read["rejectedPixels"], 3 * margin)
        # The corner post is made of the pixels left, not of the wall: it stays within a metre of what it was,
        # where the wall alone would pull it down by tens of metres.
        corner, was = posts[0, -1], clean[0, -1]
        self.assertTrue(np.isnan(corner) or abs(float(corner) - float(was)) < 1.0, (corner, was))
        self.assertFalse((posts[np.isfinite(posts)] < float(np.nanmin(clean)) - 1.0).any())
        # Without the pit the same wall is kept: it is in range, and ground for all the reader knows.
        walled = pixels.copy()
        walled[row - 1:row + 2, column:column + margin] = -9.0
        kept = posts_of(walled)
        self.assertEqual(kept[2]["rejectedPixels"], 0)
        self.assertLess(float(np.nanmin(kept[0])), float(np.nanmin(clean)) - 10.0)

    def test_a_mask_is_spread_by_its_margin_along_rows_and_columns(self):
        import numpy as np

        mask = np.zeros((9, 12), dtype=bool)
        mask[4, 5] = mask[0, 11] = True
        grown = build_elevation.spread(mask, 2)
        expected = np.zeros_like(mask)
        expected[2:7, 3:8] = expected[0:3, 9:12] = True
        np.testing.assert_array_equal(grown, expected)
        self.assertEqual(int(mask.sum()), 2)
        np.testing.assert_array_equal(build_elevation.spread(mask, 0), mask)

    def sonny_zip(self, name, heights, members=None):
        """Sonny's zip of one HGT file; `members` replaces its contents."""
        import numpy as np

        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
            for member, data in (members or [(name, np.asarray(heights, dtype=">i2").tobytes())]):
                archive.writestr(member, data)
        return stream.getvalue()

    def test_sonnys_zip_gives_a_cells_posts_and_no_other_zip_passes(self):
        import numpy as np

        cell = (8, 47)
        heights = np.tile(np.arange(self.POSTS, dtype="int16") + 400, (self.POSTS, 1))
        heights[5, 5] = build_elevation.NO_DATA
        posts, read = build_elevation.sonny_posts(self.sonny_zip("N47E008.hgt", heights), cell)
        self.assertEqual(posts.shape, (self.POSTS,) * 2)
        # The posts are the file's own, on the cell's grid; no data stays none.
        self.assertTrue(np.isnan(posts[5, 5]))
        self.assertEqual((float(posts[0, 0]), float(posts[40, 40])), (400.0, 440.0))
        self.assertEqual((read["invalidPixels"], read["rejectedPixels"], read["rejectedHeights"]), (1, 0, None))
        # A pit and a spike are not ground: they go with the posts within the margin of them.
        margin = build_elevation.SONNY_REJECT_MARGIN
        pitted = heights.copy()
        pitted[20, 20] = -30
        pitted[0, 40] = 7500
        pitted[30, 10] = -9
        posts, read = build_elevation.sonny_posts(self.sonny_zip("N47E008.hgt", pitted), cell)
        self.assertEqual(read["rejectedHeights"], [-30.0, 7500.0])
        self.assertEqual(read["rejectedPixels"], (2 * margin + 1) ** 2 + (margin + 1) ** 2)
        self.assertTrue(np.isnan(posts[20 - margin:21 + margin, 20 - margin:21 + margin]).all())
        self.assertFalse(np.isnan(posts[20 - margin - 1, 20]))
        self.assertEqual(float(posts[30, 10]), -9.0)
        # Only the cell's own HGT file, whole, passes.
        good = np.asarray(heights, dtype=">i2").tobytes()
        for members in ([("N47E009.hgt", good)], [("N47E008.hgt", good), ("readme.txt", b"x")],
                        [("N47E008.hgt", good[:-2])], [("N47E008/N47E008.hgt", good)]):
            with self.subTest(members=[name for name, _ in members]), \
                    self.assertRaisesRegex(ValueError, "not Sonny's tile of N47E008"):
                build_elevation.sonny_posts(self.sonny_zip("", None, members), cell)

    def sonny_source(self, tiles, area=None):
        return build_elevation.TerrainSource(
            "sonny-dtm-europe-1s-v25", build_elevation.SONNY_ORIGIN, tiles, "e" * 64, "https://terms.example",
            "https://credit.example", *(area or (self.AREA, "a" * 64)), build_elevation.SONNY_ADAPTER)

    def test_a_sonny_tile_must_be_the_catalogs_download(self):
        import numpy as np

        cell = (8, 47)
        heights = np.full((self.POSTS, self.POSTS), 420, dtype="int16")
        heights[10, 10] = -50
        data = self.sonny_zip("N47E008.hgt", heights)
        sha256 = hashlib.sha256(data).hexdigest()
        legacy = "0BxphPoRgwhnoMjZYbUhiLXFaTVk/0-yUN8-e7SYxqkNXtDmq8yAg"
        source = self.sonny_source({cell: (legacy, "20240715", len(data), sha256),
                                    (7, 47): ("1SR2cz3aTvEesKawAbmbm6XxOhVFF7MNq", "20240715", 9, "f" * 64)})
        # A file made before 2021 is fetched with its resource key; a newer one by its id alone.
        self.assertEqual(source.tile_url(*cell), "https://drive.usercontent.google.com/download?"
                         "id=0BxphPoRgwhnoMjZYbUhiLXFaTVk&export=download&confirm=t&resourcekey=0-yUN8-e7SYxqkNXtDmq8yAg")
        self.assertEqual(source.tile_url(7, 47), "https://drive.usercontent.google.com/download?"
                         "id=1SR2cz3aTvEesKawAbmbm6XxOhVFF7MNq&export=download&confirm=t")
        # The receipt pins the zip's size and SHA-256, in the place of an ETag, and the rule for not ground.
        self.assertEqual(source.pin(cell), {
            "source": "sonny-dtm-europe-1s-v25", "url": source.tile_url(*cell), "bytes": len(data), "etag": sha256,
            "areaSha256": "a" * 64, "rejects": {"below": -10, "above": 7000, "pixelsAround": 4}})
        fetched = []

        def fetch(url):
            fetched.append(url)
            return answers.pop(0), ""

        answers = [data]
        with patch.object(build_elevation, "fetch", fetch):
            posts, read = build_elevation.read_sonny_cell(source, cell, Path("unused"))
        self.assertEqual(fetched, [source.tile_url(*cell)])
        self.assertEqual({key: read[key] for key in ("sha256", "readBytes", "tileDate", "rejectedPixels")},
                         {"sha256": sha256, "readBytes": len(data), "tileDate": "20240715",
                          "rejectedPixels": (2 * build_elevation.SONNY_REJECT_MARGIN + 1) ** 2})
        self.assertEqual(int(np.isfinite(posts).sum()), self.POSTS ** 2 - read["rejectedPixels"])
        # Drive's page for a file it will not serve now, or a changed file, stops the cell.
        for answer in (b"<!DOCTYPE html><html>Too many users have viewed or downloaded this file</html>",
                       self.sonny_zip("N47E008.hgt", heights + 1)):
            answers = [answer]
            with self.subTest(answer=answer[:20]), patch.object(build_elevation, "fetch", fetch), \
                    self.assertRaisesRegex(ValueError, "not the catalog's"):
                build_elevation.read_sonny_cell(source, cell, Path("unused"))
        # The copy a build fetched from the bucket is read in place of Drive's; with none there, Drive's.
        with tempfile.TemporaryDirectory() as directory:
            files = Path(directory)
            copied = replace(source, files=files)
            (files / "N47E008.zip").write_bytes(data)
            fetched.clear()
            with patch.object(build_elevation, "fetch", fetch):
                posts, read = build_elevation.read_sonny_cell(copied, cell, Path("unused"))
                self.assertEqual((fetched, read["via"], read["sha256"]), ([], "mirror", sha256))
                (files / "N47E008.zip").unlink()
                answers = [data]
                self.assertEqual(build_elevation.read_sonny_cell(copied, cell, Path("unused"))[1]["via"], "origin")
                self.assertEqual(fetched, [source.tile_url(*cell)])
                # A copy that is not the catalog's stops the cell, as Drive's would.
                (files / "N47E008.zip").write_bytes(self.sonny_zip("N47E008.hgt", heights + 1))
                with self.assertRaisesRegex(ValueError, f"{files}/N47E008.zip gave .* not the catalog's"):
                    build_elevation.read_sonny_cell(copied, cell, Path("unused"))
        self.assertEqual(copied.mirror_file(cell), ("N47E008.zip", len(data), sha256))
        # Where the files come from is not what the receipt pins: a tile read from either is the same tile.
        self.assertEqual(copied.pin(cell), source.pin(cell))

    def test_the_bucket_copy_gets_each_file_once_and_only_as_pinned(self):
        files = {(8, 47): b"zurich", (9, 47): b"st-gallen", (13, 52): b"berlin"}
        tiles = {cell: (f"{cell[0]:033d}", "20240101", len(data), hashlib.sha256(data).hexdigest())
                 for cell, data in files.items()}
        source = replace(self.sonny_source(tiles), mirror="gs://bucket/copy/")
        served = {source.tile_url(*cell): data for cell, data in files.items()}
        uploaded = {}

        def upload(data, url):
            uploaded[url] = data

        def read(cell, name):
            return served[source.tile_url(*cell)]

        done = terrain_catalog.mirror_files(source, {"N47E008.zip": 6}, read, upload)
        self.assertEqual(done, {"N47E008.zip": "held", "N47E009.zip": "copied", "N52E013.zip": "copied"})
        self.assertEqual(uploaded, {"gs://bucket/copy/N47E009.zip": b"st-gallen", "gs://bucket/copy/N52E013.zip": b"berlin"})
        # Never another file than the pinned one, and never over an object.
        served[source.tile_url(13, 52)] = b"Berlin"
        with self.assertRaisesRegex(ValueError, "N52E013.zip is not the catalog's: 6 bytes with SHA-256"):
            terrain_catalog.mirror_files(source, {}, read, upload)
        with self.assertRaisesRegex(ValueError, "gs://bucket/copy/N47E009.zip holds 8 bytes, not the catalog's 9"):
            terrain_catalog.mirror_files(source, {"N47E009.zip": 8}, read, upload)

    def test_sonnys_catalog_names_each_cells_file_and_pins_it(self):
        tiles = {(8, 47): ("1SR2cz3aTvEesKawAbmbm6XxOhVFF7MNq", "20240715", 10188486, "c7" * 32),
                 (-10, 38): ("1DWITCiLuCLIkcYQRaItJX5mwSaxGkskK", "20250731", 1914899, "c3" * 32),
                 (13, 48): ("0BxphPoRgwhnoMjZYbUhiLXFaTVk/0-yUN8-e7SYxqkNXtDmq8yAg", "20240715", 8808065, "0a" * 32)}
        text = build_elevation.format_sonny_catalog(tiles)
        self.assertEqual(text.splitlines()[0], "N38W010 1DWITCiLuCLIkcYQRaItJX5mwSaxGkskK 20250731 1914899 " + "c3" * 32)
        self.assertEqual(build_elevation.parse_sonny_catalog(text), tiles)
        lines = text.splitlines(keepends=True)
        for broken, message in (
                ("".join(reversed(lines)), "not sorted"),
                (text + lines[0], "repeats a cell"),
                (text.replace("20250731", "2025-07-31"), "invalid"),
                (text.replace("c3" * 32, "c3" * 16), "invalid"),
                (text.replace("1DWITCiLuCLIkcYQRaItJX5mwSaxGkskK", "../etc"), "invalid")):
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                build_elevation.parse_sonny_catalog(broken)

    def linz_sheets(self, cell, plane, split=None, pixel=8.0, crs="EPSG:2193", shift=0, pit=None):
        """Two in-memory sheets at the 8 m overview that cover the cell's box, split at a column; heights on a plane.

        `pit` is a height put in the first sheet's last column, half way down.
        """
        import numpy as np
        import rasterio
        from affine import Affine
        from rasterio.io import MemoryFile

        west, south, east, north = build_elevation.linz_box(cell)
        west, north = west - 80, north + 80
        width, height = round((east + 80 - west) / 8), round((north - south + 80) / 8)
        split = split or width // 2
        sheets = []
        for index, (first, last) in enumerate(((0, split), (split, width))):
            left = west + first * 8
            transform = Affine(pixel, 0, left + shift, 0, -pixel, north)
            columns = np.arange(first, last) * 8 + west + 4
            rows = north - 4 - np.arange(height) * 8
            heights = plane(columns[None, :], rows[:, None]).astype("float32")
            if pit is not None and index == 0:
                heights[height // 2, -1] = pit
            memory = MemoryFile()
            with memory.open(driver="GTiff", width=last - first, height=height, count=1, dtype="float32", crs=crs,
                             transform=transform, nodata=-9999.0) as dataset:
                dataset.write(heights, 1)
            bounds = (round(left), round(north - height * 8), round(left + (last - first) * 8), round(north))
            sheets.append(((f"BQ3{index + 1}", "v" * 32, 100 + index, "0" * 32, bounds), memory))
        return sheets

    def test_linz_sheets_give_a_cells_posts_across_their_edge_and_no_other_sheet_passes(self):
        import numpy as np
        from rasterio.warp import transform

        cell = (174, -42)

        def plane(x, y):
            return 100 + 0.01 * (x - 1_750_000) + 0.02 * (y - 5_420_000)

        sheets = self.linz_sheets(cell, plane)
        datasets = [(sheet, memory.open()) for sheet, memory in sheets]
        try:
            posts, read = build_elevation.linz_posts(datasets, cell)
        finally:
            for _, dataset in datasets:
                dataset.close()
        self.assertEqual(read["sheets"], ["BQ31", "BQ32"])
        self.assertEqual((read["invalidPixels"], read["rejectedPixels"]), (0, 0))
        self.assertTrue(np.isfinite(posts).all())
        # Posts on both sides of the sheets' edge lie on the plane, read at their NZTM position.
        step = build_elevation.STEP
        for row, column in ((0, 0), (20, 20), (40, 40), (10, 35)):
            (x,), (y,) = transform("EPSG:4167", "EPSG:2193", [174 + column * step], [-41 - row * step])
            self.assertAlmostEqual(float(posts[row, column]), float(plane(x, y)), delta=0.05)
        # A pit on one sheet's edge is dropped with its margin on both sheets.
        pitted = self.linz_sheets(cell, plane, pit=-60.0)
        datasets = [(sheet, memory.open()) for sheet, memory in pitted]
        try:
            posts, read = build_elevation.linz_posts(datasets, cell)
        finally:
            for _, dataset in datasets:
                dataset.close()
        margin = build_elevation.LINZ_REJECT_MARGIN
        self.assertEqual(read["rejectedHeights"], [-60.0, -60.0])
        self.assertEqual(read["rejectedPixels"], (2 * margin + 1) ** 2)
        self.assertTrue(np.isnan(posts).any())
        # Only sheets laid out as the catalog says pass.
        for wrong in (self.linz_sheets(cell, plane, pixel=16.0), self.linz_sheets(cell, plane, crs="EPSG:3857"),
                      self.linz_sheets(cell, plane, shift=8)):
            datasets = [(sheet, memory.open()) for sheet, memory in wrong]
            try:
                with self.assertRaisesRegex(ValueError, "not LINZ's sheet BQ31 at its 8 m overview"):
                    build_elevation.linz_posts(datasets, cell)
            finally:
                for _, dataset in datasets:
                    dataset.close()

    def test_linzs_catalog_pins_each_sheets_version_and_each_cells_sheets(self):
        sheet = ("BQ31", "DodWRHAUJE46xi.22NA3hC311ulZYS7L", 509806020, "f9550225fb2526ca684796b139c48d38-42",
                 (1732000, 5406000, 1756000, 5442000))
        other = ("BQ32", "nk4_RRlf3zejc8fkNXKaciWJUUB391l4", 1090754564, "63e95ad88961f4fcba8e67fb3c303892-42",
                 (1756000, 5406000, 1780000, 5442000))
        tiles = {(174, -42): (sheet, other), (175, -42): (other,)}
        text = build_elevation.format_linz_catalog(tiles)
        self.assertEqual(text.splitlines(), [
            "sheet BQ31 DodWRHAUJE46xi.22NA3hC311ulZYS7L 509806020 f9550225fb2526ca684796b139c48d38-42 "
            "1732000 5406000 1756000 5442000",
            "sheet BQ32 nk4_RRlf3zejc8fkNXKaciWJUUB391l4 1090754564 63e95ad88961f4fcba8e67fb3c303892-42 "
            "1756000 5406000 1780000 5442000",
            "cell S42E174 BQ31 BQ32", "cell S42E175 BQ32"])
        self.assertEqual(build_elevation.parse_linz_catalog(text), tiles)
        for broken, message in (
                (text.replace("cell S42E175 BQ32", "cell S42E175 BQ33"), "unknown sheet"),
                (text.replace("cell S42E174 BQ31 BQ32", "cell S42E174 BQ32 BQ31"), "unknown sheet"),
                (text + "cell S42E175 BQ32\n", "repeats a cell"),
                (text.replace(" 1756000 5442000\n", " 1732000 5442000\n", 1), "empty bounds"),
                (text.replace("cell S42E174 BQ31 BQ32\n", ""), "unknown sheet|no cell reads"),
                (text.replace("sheet BQ31", "sheet bq31"), "invalid")):
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                build_elevation.parse_linz_catalog(broken)
        source = build_elevation.TerrainSource(
            "linz-nz-lidar-1m-dem", build_elevation.LINZ_ORIGIN, tiles, "f" * 64, "https://terms.example",
            "https://credit.example", self.AREA, "a" * 64, build_elevation.LINZ_ADAPTER)
        pinned = hashlib.sha256((f"BQ31 {sheet[1]} {sheet[2]} {sheet[3]}\n"
                                 f"BQ32 {other[1]} {other[2]} {other[3]}\n").encode()).hexdigest()
        self.assertEqual(source.pin((174, -42)), {
            "source": "linz-nz-lidar-1m-dem", "url": build_elevation.LINZ_ORIGIN, "bytes": sheet[2] + other[2],
            "etag": pinned, "areaSha256": "a" * 64, "rejects": {"below": -10, "above": 4000, "pixelsAround": 15}})
        self.assertEqual(build_elevation.linz_url(build_elevation.LINZ_ORIGIN, *sheet[:2]),
                         build_elevation.LINZ_ORIGIN + "/BQ31.tiff?versionId=DodWRHAUJE46xi.22NA3hC311ulZYS7L")
        # A cell reads only the pinned versions: a sheet whose size or ETag differs stops it before it is read.
        with patch.object(build_elevation, "object_identity", lambda url: (1, "0" * 32)), \
                self.assertRaisesRegex(ValueError, "not the catalog's 509806020 bytes"):
            build_elevation.read_linz_cell(source, (174, -42), Path("unused"))

    def test_the_mrdem_object_must_be_the_pinned_one_before_and_after_a_cell_reads_it(self):
        import numpy as np

        cell = (-80, 43)
        memory, height = self.mrdem_raster(cell)
        pinned = (83854027098, "1b" * 16 + "-9997")
        with tempfile.TemporaryDirectory() as tmp, memory:
            out = Path(tmp)
            (out / "receipts").mkdir()
            area = self.write_area(out / "area.geojson.gz", [(-81, 42), (-78, 42), (-78, 45), (-81, 45)])
            source = build_elevation.TerrainSource(
                "nrcan-mrdem-30", build_elevation.MRDEM_URL, {cell: None}, "c" * 64, "https://terms.example",
                "https://credit.example", *area, build_elevation.MRDEM_ADAPTER, pinned)
            opened = []

            def open_raster(path):
                opened.append(path)
                return memory.open()

            with patch("rasterio.open", open_raster), \
                    patch.object(build_elevation, "object_identity", return_value=pinned) as asked:
                receipt = build_elevation.build_terrain_cell(cell, {cell: (source,)}, out)
            self.assertEqual(opened, ["/vsicurl/" + build_elevation.MRDEM_URL])
            self.assertEqual(asked.call_count, 2)
            part, = receipt["sources"]
            self.assertEqual({field: part[field] for field in build_elevation.PIN_FIELDS}, {
                "source": "nrcan-mrdem-30", "url": build_elevation.MRDEM_URL, "bytes": pinned[0], "etag": pinned[1],
                "areaSha256": area[1], "rejects": {"below": -10, "above": 7000, "pixelsAround": 4}})
            self.assertEqual((part["rejectedPixels"], part["rejectedHeights"], receipt["rejectedPixels"]), (0, None, 0))
            # A tile read before pixels that are not ground were dropped names no such rule, and is built again.
            earlier = json.loads(json.dumps(receipt))
            del earlier["sources"][0]["rejects"]
            build_elevation.write_receipt(out, earlier)
            self.assertIsNone(build_elevation.current_terrain_receipt(out, cell, {cell: (source,)}))
            build_elevation.write_receipt(out, receipt)
            # What was read is the window's pixels, not the 84 GB object.
            width, height_ = part["window"][2:]
            self.assertEqual((part["readBytes"], receipt["bytes"], part["posts"], part["outsidePosts"]),
                             (4 * width * height_, 4 * width * height_, self.POSTS ** 2, 0))
            posts = build_elevation.read_tile(build_elevation.hgt_path(out, *cell))[0]
            np.testing.assert_allclose(posts.ravel(), height(*self.post_positions(cell)), atol=0.62)
            self.assertEqual(build_elevation.current_terrain_receipt(out, cell, {cell: (source,)}), receipt)
            self.assertEqual(source.identity()["originEtag"], pinned[1])
            # A replaced object makes the tile stale and stops the next read, whenever the change shows.
            replaced = build_elevation.TerrainSource(
                "nrcan-mrdem-30", build_elevation.MRDEM_URL, {cell: None}, "c" * 64, "https://terms.example",
                "https://credit.example", *area, build_elevation.MRDEM_ADAPTER, (pinned[0], "2c" * 16 + "-9997"))
            self.assertIsNone(build_elevation.current_terrain_receipt(out, cell, {cell: (replaced,)}))
            for answers in ([(pinned[0] + 1, pinned[1])], [pinned, (pinned[0], "2c" * 16 + "-9997")]):
                with self.subTest(answers=answers), patch("rasterio.open", open_raster), \
                        patch.object(build_elevation, "object_identity", side_effect=answers), \
                        self.assertRaisesRegex(ValueError, "not the pinned"):
                    build_elevation.build_terrain_cell(cell, {cell: (source,)}, out)

    def test_a_border_cell_takes_each_post_from_the_source_whose_area_holds_it(self):
        import numpy as np

        cell = (-80, 43)
        step = build_elevation.STEP
        side = (self.POSTS - 1) * 3 + 12
        with self.terrain_tile(cell, np.full((side, side), 31.4, dtype="float32")) as tile:
            data = tile.read()
        etag = hashlib.md5(data).hexdigest()
        memory, height = self.mrdem_raster(cell)
        pinned = (83854027098, "1b" * 16 + "-9997")
        with tempfile.TemporaryDirectory() as tmp, memory:
            out = Path(tmp)
            (out / "receipts").mkdir()
            # The first area ends between post columns 20 and 21; the second begins between columns 17 and 18,
            # so both hold columns 18 to 20.
            east, west = -80 + 20.5 * step, -80 + 17.5 * step
            first = self.write_area(out / "first.geojson.gz", [(-81, 42), (east, 42), (east, 45), (-81, 45)])
            second = self.write_area(out / "second.geojson.gz", [(west, 42), (-78, 42), (-78, 45), (west, 45)])
            usgs = build_elevation.TerrainSource(
                "usgs-3dep-13", "https://terrain.example", {cell: ("n44w080", "20230227", len(data), etag)},
                "c" * 64, "https://terms.example", "https://credit.example", *first)
            mrdem = build_elevation.TerrainSource(
                "nrcan-mrdem-30", build_elevation.MRDEM_URL, {cell: None, (-79, 43): None}, "d" * 64,
                "https://terms.example", "https://credit.example", *second, build_elevation.MRDEM_ADAPTER, pinned)
            terrain = build_elevation.Terrain.over((usgs, mrdem), [(-81, 43), cell, (-79, 43)])
            self.assertEqual((terrain.ids(), terrain.cells), (
                ["usgs-3dep-13", "nrcan-mrdem-30"], {cell: (usgs, mrdem), (-79, 43): (mrdem,)}))
            import rasterio
            open_file = rasterio.open

            def open_raster(path):
                return memory.open() if str(path).startswith("/vsicurl/") else open_file(path)

            def fetch_range(url, start, end):
                return data[start:end], len(data), etag

            with patch("rasterio.open", open_raster), patch.object(build_elevation, "fetch_range", fetch_range), \
                    patch.object(build_elevation, "object_identity", return_value=pinned):
                receipt = build_elevation.build_terrain_cell(cell, terrain.cells, out)
            posts = build_elevation.read_tile(build_elevation.hgt_path(out, *cell))[0]
            np.testing.assert_array_equal(posts[:, :21], 31)
            longitudes, latitudes = self.post_positions(cell)
            np.testing.assert_allclose(posts[:, 21:], height(longitudes, latitudes).reshape(posts.shape)[:, 21:],
                                       atol=0.62)
            self.assertEqual([(part["source"], part["posts"], part["outsidePosts"]) for part in receipt["sources"]],
                             [("usgs-3dep-13", self.POSTS * 21, self.POSTS * 20),
                              ("nrcan-mrdem-30", self.POSTS * 20, self.POSTS * 18)])
            self.assertEqual((receipt["outsidePosts"], receipt["noDataPosts"]), (self.POSTS * 38, 0))
            self.assertEqual(receipt["bytes"], len(data) + receipt["sources"][1]["readBytes"])
            self.assertEqual(build_elevation.current_terrain_receipt(out, cell, terrain.cells), receipt)
            # The tile is stale once the cell's sources are others, fewer or in another order.
            for others in ((usgs,), (mrdem,), (mrdem, usgs)):
                self.assertIsNone(build_elevation.current_terrain_receipt(out, cell, {cell: others}))
            self.assertEqual(build_elevation.terrain_shares(terrain, [receipt]), [
                {**usgs.identity(), "cells": 1, "posts": self.POSTS * 21, "rejectedPixels": 0},
                {**mrdem.identity(), "cells": 1, "posts": self.POSTS * 20, "rejectedPixels": 0}])

    def test_an_objects_size_and_etag_come_from_a_head_request(self):
        class Response:
            headers = {"Content-Length": "83854027098", "ETag": '"1bf0-9997"'}

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        asked = []

        def urlopen(request, timeout):
            asked.append((request.get_method(), request.full_url))
            if len(asked) == 1:
                raise ConnectionResetError("reset")
            return Response()

        with patch.object(build_elevation.urllib.request, "urlopen", urlopen), patch.object(build_elevation.time, "sleep"):
            self.assertEqual(build_elevation.object_identity("https://u/o.tif"), (83854027098, "1bf0-9997"))
        self.assertEqual(asked, [("HEAD", "https://u/o.tif")] * 2)

    @staticmethod
    def write_area(path, ring):
        """A gzipped GeoJSON area of one ring; returns its path and SHA-256."""
        feature = {"type": "Feature", "properties": {}, "geometry": {"type": "Polygon", "coordinates": [[*ring, ring[0]]]}}
        data = terrain_catalog.area_bytes(feature)
        path.write_bytes(data)
        return path, hashlib.sha256(data).hexdigest()

    def test_posts_outside_the_area_are_dropped_whatever_the_tile_holds(self):
        import numpy as np

        step = build_elevation.STEP
        with tempfile.TemporaryDirectory() as tmp:
            # The posts span 40 arc-seconds from the cell's north-west corner (-74, 41). The area's edge runs
            # between post columns 10 and 11 and post rows 20 and 21.
            east, south = -74 + 10.5 * step, 41 - 20.5 * step
            path, sha256 = self.write_area(Path(tmp) / "area.geojson.gz", [(-76, south), (east, south), (east, 43), (-76, 43)])
            area = build_elevation.load_area(path, sha256)
            inside = build_elevation.posts_in_area((-74, 40), area)
            self.assertEqual(inside.shape, (self.POSTS,) * 2)
            self.assertTrue(inside[:21, :11].all())
            self.assertEqual(int(inside.sum()), 21 * 11)
            heights = np.full((self.POSTS,) * 2, 5, dtype="float32")
            heights[0, 0] = heights[30, 30] = np.nan
            self.assertEqual(build_elevation.clip_to_area(heights, (-74, 40), area), self.POSTS ** 2 - 21 * 11 - 1)
            self.assertEqual(int(np.isfinite(heights).sum()), 21 * 11 - 1)
            # A cell wholly inside keeps every post, one wholly outside none.
            self.assertIs(build_elevation.posts_in_area((-75, 41), area), True)
            self.assertIs(build_elevation.posts_in_area((-73, 40), area), False)
            full = np.full((self.POSTS,) * 2, 5, dtype="float32")
            self.assertEqual(build_elevation.clip_to_area(full, (-75, 41), area), 0)
            self.assertEqual(build_elevation.clip_to_area(full, (-73, 40), area), self.POSTS ** 2)
            self.assertTrue(np.isnan(full).all())
            with self.assertRaisesRegex(ValueError, "not the area"):
                build_elevation.load_area(path, "0" * 64)
            (Path(tmp) / "line.geojson.gz").write_bytes(terrain_catalog.area_bytes(
                {"type": "Feature", "properties": {}, "geometry": {"type": "LineString", "coordinates": [[0, 0], [1, 1]]}}))
            line = Path(tmp) / "line.geojson.gz"
            with self.assertRaisesRegex(ValueError, "one GeoJSON polygon"):
                build_elevation.load_area(line, hashlib.sha256(line.read_bytes()).hexdigest())

    def test_hybrid_arguments_go_together_and_keep_their_directories_apart(self):
        sources = str(Path(build_elevation.__file__).with_name("elevation-sources.json"))
        opened = ["--opening-radius", "400", "--raw", "raw"]
        for arguments in (["--terrain-sources", sources], [*opened, "--terrain-sources", sources, "--terrain", "t"],
                          ["--terrain-sources", sources, "--terrain", "t", "--opened", "o"],
                          [*opened, "--terrain-sources", sources, "--terrain", "out/t", "--opened", "o"],
                          [*opened, "--terrain-sources", sources, "--terrain", "t", "--opened", "raw"],
                          [*opened, "--terrain-sources", "missing.json", "--terrain", "t", "--opened", "o"],
                          [*opened, "--terrain-files", "f"]):
            argv = ["build_elevation.py", "--policy", "missing.json", "--out", "out", *arguments]
            with self.subTest(arguments=arguments), patch("sys.argv", argv), \
                    patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                build_elevation.main()


class TerrainSourceTests(unittest.TestCase):
    ROUTING = Path(build_elevation.__file__).parent

    def test_the_checked_in_source_list_pins_its_catalog_and_its_approval(self):
        source, canada, europe, zealand, hong_kong, japan = build_elevation.load_terrain_sources(
            self.ROUTING / "elevation-sources.json")
        self.assertEqual((source.id, len(source.tiles), source.origin_object), ("usgs-3dep-13", 955, None))
        self.assertEqual(source.tile_url(-74, 40), "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/"
                                                   "historical/n41w074/USGS_13_n41w074_20260917.tif")
        # The conterminous United States only: nothing in Alaska, Hawaii or the territories.
        self.assertTrue(all(-125 <= x <= -66 and 24 <= y <= 49 for x, y in source.tiles))
        # Every tile's cell touches the area, and cells wholly in Mexico or Canada are not listed.
        area = build_elevation.load_area(source.area, source.area_sha256)
        self.assertEqual((source.area.name, area[0].geom_type), (
            "united-states-conterminous-osm-r148838-v1054.geojson.gz", "MultiPolygon"))
        self.assertTrue(all(terrain_catalog.touches_area(cell, area) for cell in source.tiles))
        self.assertFalse({(-107, 30), (-101, 27)} & set(source.tiles))
        # Tijuana, Ciudad Juarez and Windsor are outside; San Ysidro, El Paso and Detroit inside.
        from shapely.geometry import Point
        self.assertEqual([area[1].contains(Point(x, y)) for x, y in (
            (-117.0382, 32.5330), (-106.4850, 31.7380), (-83.0300, 42.3100),
            (-117.0300, 32.5480), (-106.4850, 31.7600), (-83.0500, 42.3350))], [False] * 3 + [True] * 3)
        # Canada's source is one object, pinned by size and ETag, over the cells that touch Canada.
        self.assertEqual((canada.id, len(canada.tiles), canada.origin_object, canada.tile_url(-80, 43)), (
            "nrcan-mrdem-30", 2480, (83854027098, "1bf055857edce86b1311967c8d88395e-9997"),
            "https://canelevation-dem.s3.ca-central-1.amazonaws.com/mrdem-30/mrdem-30-dtm.tif"))
        self.assertEqual(set(canada.tiles.values()), {None})
        self.assertEqual(canada.pin((-80, 43)), {
            "source": "nrcan-mrdem-30", "url": canada.origin, "bytes": 83854027098,
            "etag": "1bf055857edce86b1311967c8d88395e-9997", "areaSha256": canada.area_sha256,
            "rejects": {"below": -10, "above": 7000, "pixelsAround": 4}})
        self.assertIsNone(source.pin((-74, 40))["rejects"])
        north = build_elevation.load_area(canada.area, canada.area_sha256)
        self.assertEqual(canada.area.name, "canada-osm-r1428125-v649.geojson.gz")
        self.assertEqual(sorted(canada.tiles), sorted(terrain_catalog.area_cells(north)))
        # Windsor, Toronto, Vancouver and Alert are inside; Detroit, Niagara Falls NY, Point Roberts and Hyder outside.
        self.assertEqual([north[1].contains(Point(x, y)) for x, y in (
            (-83.0300, 42.3100), (-79.3790, 43.6462), (-123.1207, 49.2827), (-62.35, 82.5),
            (-83.0500, 42.3350), (-79.0550, 43.0850), (-123.0700, 48.9850), (-130.02, 55.917))], [True] * 4 + [False] * 4)
        # The two countries share the border's ways. Their areas overlap only in the sea around Machias Seal
        # Island, which both claim; there the first source gives the posts it has.
        both = [part for part in area[0].intersection(north[0]).geoms if part.area > 0]
        self.assertEqual(len(both), 1)
        self.assertTrue(box(-67.31, 44.29, -66.92, 44.76).contains(both[0]) and 0.06 < both[0].area < 0.07, both[0].bounds)
        strip = box(-123.2, 48.9, -95.2, 49.1)
        self.assertAlmostEqual(area[0].union(north[0]).intersection(strip).area, strip.area, places=9)
        terrain = build_elevation.Terrain.over((source, canada), sorted(set(source.tiles) | set(canada.tiles)))
        self.assertEqual((len(terrain.cells), sum(1 for found in terrain.cells.values() if len(found) == 2)), (3340, 95))
        self.assertEqual(terrain.cells[(-80, 43)], (source, canada))
        # Sonny's tiles of Europe: a Drive file per cell, pinned by size and SHA-256, cut to the countries it builds
        # from national terrain models and to mainland Portugal outside the patch of SRTM around Porto.
        self.assertEqual((europe.id, len(europe.tiles), europe.origin_object), ("sonny-dtm-europe-1s-v25", 848, None))
        # A copy of every file is kept in the elevation bucket, which a build reads before Drive.
        self.assertEqual(europe.mirror, "gs://bicino-routing-elevation/terrain-sources/sonny-dtm-europe-1s-v25/")
        self.assertEqual(europe.tile_url(-10, 38), "https://drive.usercontent.google.com/download?"
                                                   "id=1DWITCiLuCLIkcYQRaItJX5mwSaxGkskK&export=download&confirm=t")
        self.assertTrue(europe.tile_url(13, 48).endswith("&resourcekey=0-yUN8-e7SYxqkNXtDmq8yAg"))
        self.assertEqual(europe.pin((-10, 38)), {
            "source": "sonny-dtm-europe-1s-v25", "url": europe.tile_url(-10, 38), "bytes": 1914899,
            "etag": "c30fd24b6ae4a4d13b99e0891c3b034bab3d25d7c662941205cbacb74bc0c8be", "areaSha256": europe.area_sha256,
            "rejects": {"below": -10, "above": 7000, "pixelsAround": 4}})
        europe_area = build_elevation.load_area(europe.area, europe.area_sha256)
        self.assertEqual(europe.area.name, "sonny-europe-osm-20261127.geojson.gz")
        self.assertTrue(all(terrain_catalog.touches_area(cell, europe_area) for cell in europe.tiles))
        # Lisbon, Coimbra, Zurich, Stuttgart, Amsterdam, Belfast, Bratislava, Oslo and Palma are inside; Porto,
        # Braga, Funchal, Rome, Budapest, Dublin, Zagreb, Vaduz and Andorra la Vella outside.
        self.assertEqual([europe_area[1].contains(Point(x, y)) for x, y in (
            (-9.14, 38.71), (-8.43, 40.21), (8.54, 47.37), (9.18, 48.78), (4.90, 52.37), (-5.93, 54.60),
            (17.11, 48.15), (10.75, 59.91), (2.65, 39.57),
            (-8.61, 41.15), (-8.42, 41.55), (-16.91, 32.65), (12.50, 41.90), (19.04, 47.50), (-6.26, 53.35),
            (15.98, 45.81), (9.52, 47.14), (1.52, 42.51))], [True] * 9 + [False] * 9)
        # LINZ's lidar of New Zealand: the latest version of each sheet the 60 cells of its capture area read.
        self.assertEqual((zealand.id, len(zealand.tiles), zealand.tile_url(174, -42)),
                         ("linz-nz-lidar-1m-dem", 60, build_elevation.LINZ_ORIGIN))
        wellington = zealand.tiles[(174, -42)]
        self.assertEqual([sheet[0] for sheet in wellington], [
            "BP28", "BP29", "BP30", "BP31", "BP32", "BQ28", "BQ29", "BQ30", "BQ31", "BQ32", "BR28", "BR29", "BS28",
            "BS29"])
        self.assertEqual(wellington[8], ("BQ31", "DodWRHAUJE46xi.22NA3hC311ulZYS7L", 509806020,
                                         "f9550225fb2526ca684796b139c48d38-42", (1732000, 5406000, 1756000, 5442000)))
        self.assertEqual(zealand.pin((174, -42))["etag"],
                         "170c465a4749f56438ecf69ba6f4e6846b1bce07dada65a36c10d7607d067d20")
        capture = build_elevation.load_area(zealand.area, zealand.area_sha256)
        self.assertTrue(all(terrain_catalog.touches_area(cell, capture) for cell in zealand.tiles))
        # Wellington, Auckland, Christchurch, Dunedin and Queenstown are inside; the Chatham Islands outside.
        self.assertEqual([capture[1].contains(Point(x, y)) for x, y in (
            (174.7762, -41.2865), (174.7633, -36.8485), (172.6362, -43.5321), (170.5028, -45.8788),
            (168.6626, -45.0312), (-176.56, -43.95))], [True] * 5 + [False])
        # CEDD's lidar of Hong Kong: two cells kept as HGT tiles in the elevation bucket, read from there alone.
        self.assertEqual((hong_kong.id, sorted(hong_kong.tiles), hong_kong.mirror),
                         ("cedd-hk-lidar-dtm-2020", [(113, 22), (114, 22)],
                          "gs://bicino-routing-elevation/terrain-sources/cedd-hk-lidar-dtm-2020/"))
        self.assertEqual(hong_kong.pin((114, 22)), {
            "source": "cedd-hk-lidar-dtm-2020", "url": f"{hong_kong.mirror}N22E114.hgt.gz", "bytes": 1355799,
            "etag": "40f550af0f00e82c5720f9fce618ad84cd7ea68871fa1f82933abde2ed8d74e4",
            "areaSha256": hong_kong.area_sha256, "rejects": {"below": -10, "above": 1000, "pixelsAround": 24}})
        self.assertEqual(hong_kong.provenance_file((114, 22)),
                         ("N22E114.txt", "a7774cf4d6c078f369984d0f122ab4d643d697d5071e1e7f42495e11b7ed980b"))
        hong_kong_area = build_elevation.load_area(hong_kong.area, hong_kong.area_sha256)
        # Central, Tai Mo Shan and Lantau are inside; Shenzhen and Macau outside.
        self.assertEqual([hong_kong_area[1].contains(Point(x, y)) for x, y in (
            (114.1588, 22.2820), (114.1244, 22.4106), (113.9440, 22.2550), (114.0579, 22.5431), (113.5439, 22.1987))],
            [True] * 3 + [False] * 2)
        # GSI's tiles of Japan: the 122 cells that touch the area and hold land, kept in the elevation bucket.
        self.assertEqual((japan.id, len(japan.tiles), japan.mirror), (
            "gsi-japan-dem5a-dem10b-20261127", 122,
            "gs://bicino-routing-elevation/terrain-sources/gsi-japan-dem5a-dem10b-20261127/"))
        self.assertEqual(japan.pin((139, 35)), {
            "source": "gsi-japan-dem5a-dem10b-20261127", "url": f"{japan.mirror}N35E139.hgt.gz", "bytes": 8261517,
            "etag": "6dfd414476059d31f7f1e754479164a45c6b6ae98eb3aae5528a8602e453f289",
            "areaSha256": japan.area_sha256, "rejects": {"below": -10, "above": 4000, "pixelsAround": 15}})
        self.assertEqual(japan.provenance_file((139, 35)),
                         ("N35E139.txt", "af869b8af1fafc66959da67cf30a7a2758d6d6784758fe7c906d0947139f163f"))
        japan_area = build_elevation.load_area(japan.area, japan.area_sha256)
        self.assertTrue(all(terrain_catalog.touches_area(cell, japan_area) for cell in japan.tiles))
        # Tokyo, Mount Fuji, Sapporo, Naha and Fukuoka are inside; Busan, Seoul and Vladivostok outside.
        self.assertEqual([japan_area[1].contains(Point(x, y)) for x, y in (
            (139.7671, 35.6812), (138.7274, 35.3607), (141.3544, 43.0621), (127.6809, 26.2124), (130.4017, 33.5902),
            (129.0756, 35.1796), (126.9780, 37.5665), (131.8855, 43.1155))], [True] * 5 + [False] * 3)
        # Europe, New Zealand, Hong Kong and Japan touch neither North American area, so every cell keeps the one
        # source it has.
        everywhere = build_elevation.Terrain.over((source, canada, europe, zealand, hong_kong, japan), sorted(
            set(source.tiles) | set(canada.tiles) | set(europe.tiles) | set(zealand.tiles) | set(hong_kong.tiles)
            | set(japan.tiles)))
        self.assertEqual((len(everywhere.cells), sum(1 for found in everywhere.cells.values() if len(found) > 1)),
                         (3340 + 848 + 60 + 2 + 122, 95))
        document = json.loads((self.ROUTING / "elevation-sources.json").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            files = {value[kind]: (self.ROUTING / value[kind]).read_bytes()
                     for value in document["terrain"] for kind in ("catalog", "area")}
            catalog = files[document["terrain"][0]["catalog"]].decode()
            area_bytes = files[document["terrain"][0]["area"]]

            def load(change, catalog_text=catalog, area=area_bytes, index=0):
                value = json.loads(json.dumps(document))
                change(value["terrain"][index])
                (root / "elevation-sources.json").write_text(json.dumps(value))
                for name, data in files.items():
                    (root / name).write_bytes(data)
                (root / document["terrain"][0]["catalog"]).write_text(catalog_text)
                (root / document["terrain"][0]["area"]).write_bytes(area)
                return build_elevation.load_terrain_sources(root / "elevation-sources.json")

            self.assertEqual([found.tiles for found in load(lambda value: None)],
                             [source.tiles, canada.tiles, europe.tiles, zealand.tiles, hong_kong.tiles, japan.tiles])
            for change, message in (
                (lambda value: value.update(approvedForRouting=False), "not approved"),
                (lambda value: value.update(approvedForRouting="yes"), "not approved"),
                (lambda value: value.update(origin="https://example.org/tiles"), "unsupported"),
                (lambda value: value.update(surfaceModel="dsm"), "unsupported"),
                (lambda value: value.update(catalog="../" + value["catalog"]), "beside the source list"),
                (lambda value: value.update(tileCount=954), "not 954"),
                (lambda value: value.update(area="../" + value["area"]), "beside the source list"),
                (lambda value: value.update(termsUrl="http://usgs.example"), "HTTPS"),
                (lambda value: value.pop("approvedBy"), "fields"),
                (lambda value: value.update(originBytes=1, originEtag="0" * 32), "fields"),
                (lambda value: value.update(adapter="other-dem-v1"), "adapter"),
                (lambda value: value.update(id="nrcan-mrdem-30"), "twice"),
            ):
                with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                    load(change)
            for change, message in (
                (lambda value: value.update(approvedForRouting=False), "nrcan-mrdem-30 is not approved"),
                (lambda value: value.update(origin=value["origin"].replace("dtm", "dsm")), "unsupported"),
                (lambda value: value.update(horizontalCrs="EPSG:4269"), "unsupported"),
                (lambda value: value.update(originBytes="83854027098"), "size, ETag and date"),
                (lambda value: value.update(originBytes=True), "size, ETag and date"),
                (lambda value: value.update(originEtag="W/1bf0"), "size, ETag and date"),
                (lambda value: value.update(originModified="24 June 2026"), "size, ETag and date"),
                (lambda value: value.pop("originEtag"), "fields"),
                (lambda value: value.update(tileCount=2479), "not 2479"),
                (lambda value: value.update(catalog=document["terrain"][0]["catalog"]), "not the catalog"),
            ):
                with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                    load(change, index=1)
            for change, message in (
                (lambda value: value.update(approvedForRouting=False), "sonny-dtm-europe-1s-v25 is not approved"),
                (lambda value: value.update(origin="https://drive.google.com/uc"), "unsupported"),
                (lambda value: value.update(horizontalCrs="EPSG:3035"), "unsupported"),
                (lambda value: value.update(tileCount=847), "not 847"),
                (lambda value: value.pop("mirror"), "fields"),
                (lambda value: value.update(mirror="gs://bicino-routing-elevation"), "gs://BUCKET/PREFIX/"),
                (lambda value: value.update(mirror="https://storage.googleapis.com/b/"), "gs://BUCKET/PREFIX/"),
                (lambda value: value.update(mirror="gs://Bucket/terrain/"), "gs://BUCKET/PREFIX/"),
                (lambda value: value.update(mirror="gs://bucket/../terrain/"), "gs://BUCKET/PREFIX/"),
                (lambda value: value.update(area=document["terrain"][1]["area"]), "not the area"),
            ):
                with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                    load(change, index=2)
            # A kept source is read from its bucket copy alone, so it must name one.
            for change, message in (
                (lambda value: value.pop("mirror"), "fields"),
                (lambda value: value.update(mirror="https://storage.googleapis.com/x/"), "gs://BUCKET/PREFIX/"),
                (lambda value: value.update(horizontalCrs="EPSG:4326"), "unsupported"),
                (lambda value: value.update(tileCount=3), "not 3"),
            ):
                with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                    load(change, index=4)
            for change, message in (
                (lambda value: value.update(approvedForRouting=False), "gsi-japan-dem5a-dem10b-20261127 is not approved"),
                (lambda value: value.update(origin=value["origin"] + "/dem5b_png"), "unsupported"),
                (lambda value: value.update(horizontalCrs="EPSG:4612"), "unsupported"),
                (lambda value: value.pop("mirror"), "fields"),
                (lambda value: value.update(tileCount=151), "not 151"),
                (lambda value: value.update(catalog=document["terrain"][4]["catalog"]), "not the catalog"),
            ):
                with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                    load(change, index=5)
            for change, message in (
                (lambda value: value.update(approvedForRouting=False), "linz-nz-lidar-1m-dem is not approved"),
                (lambda value: value.update(origin=value["origin"].replace("dem_1m", "dsm_1m")), "unsupported"),
                (lambda value: value.update(horizontalCrs="EPSG:4167"), "unsupported"),
                (lambda value: value.update(tileCount=59), "not 59"),
                (lambda value: value.update(catalog=document["terrain"][2]["catalog"]), "not the catalog"),
            ):
                with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                    load(change, index=3)
            with self.assertRaisesRegex(ValueError, "not the catalog"):
                load(lambda value: None, catalog.replace("20260917", "20260918"))
            with self.assertRaisesRegex(ValueError, "not the area"):
                load(lambda value: None, area=area_bytes + b"x")
            one = {**document, "schemaVersion": 1, "terrain": document["terrain"][:1]}
            for text in ("[]", '{"schemaVersion": 2, "terrain": []}', '{"schemaVersion": 2}', json.dumps(one)):
                (root / "elevation-sources.json").write_text(text)
                with self.subTest(text=text), self.assertRaisesRegex(ValueError, "under schemaVersion 2"):
                    build_elevation.load_terrain_sources(root / "elevation-sources.json")
            for text in ('{"schemaVersion": 2, "terrain": [{}]}', '{"schemaVersion": 2, "terrain": ["usgs-3dep-13"]}',
                         '{"schemaVersion": 2, "terrain": [{"adapter": ["usgs-3dep-13-geotiff-v1"]}]}'):
                (root / "elevation-sources.json").write_text(text)
                with self.subTest(text=text), self.assertRaisesRegex(ValueError, "adapter"):
                    build_elevation.load_terrain_sources(root / "elevation-sources.json")

    def test_a_cell_catalog_names_each_cell_once_in_order(self):
        cells = {(-80, 43): None, (-53, 47): None, (-141, 60): None}
        text = build_elevation.format_cell_catalog(cells)
        self.assertEqual(text, "N43W080\nN47W053\nN60W141\n")
        self.assertEqual(build_elevation.parse_cell_catalog(text), cells)
        for bad in ("N47W053\nN43W080\n", text + "N60W141\n", "N43W080", text.replace("N43W080", "n44w080"),
                    text.replace("N47W053", "N47W053 n48w053 20260917 5 " + "0" * 32)):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                build_elevation.parse_cell_catalog(bad)

    def test_the_cells_of_an_area_are_those_a_post_of_which_can_lie_in_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            # One arc-second short of whole degrees: the eastern and northern neighbours' border posts are not reached.
            edge = build_elevation.STEP
            path, sha256 = ElevationHybridTests.write_area(
                Path(tmp) / "area.geojson.gz",
                [(-80.5, 43.5), (-79 - edge, 43.5), (-79 - edge, 45 - edge), (-80.5, 45 - edge)])
            area = build_elevation.load_area(path, sha256)
            self.assertEqual(terrain_catalog.area_cells(area), [(-81, 43), (-81, 44), (-80, 43), (-80, 44)])
            # An area that ends on whole degrees shares those lines of posts with the cells around it.
            path, sha256 = ElevationHybridTests.write_area(
                Path(tmp) / "whole.geojson.gz", [(-80, 43), (-79, 43), (-79, 44), (-80, 44)])
            whole = terrain_catalog.area_cells(build_elevation.load_area(path, sha256))
            self.assertEqual(len(whole), 9)
            self.assertEqual(build_elevation.format_cell_catalog(whole).splitlines()[4], "N43W080")

    def test_catalog_lines_name_one_dated_tile_per_cell(self):
        tiles = {(-74, 40): ("n41w074", "20260917", 165776270, "02fe0b7c39d43b570742e25e02c0462c"),
                 (-88, 41): ("n42w088", "20260902", 348304242, "db44654aaecc53df42757080210fca19-67")}
        text = build_elevation.format_terrain_catalog(tiles)
        self.assertEqual(text.splitlines()[0], "N40W074 n41w074 20260917 165776270 02fe0b7c39d43b570742e25e02c0462c")
        self.assertEqual(build_elevation.parse_terrain_catalog(text), tiles)
        for bad in (text.replace("n41w074", "n41w075"), text + text.splitlines()[0] + "\n",
                    "".join(reversed(text.splitlines(keepends=True))), text.replace(" 165776270", " 0"),
                    text.replace("20260917", "2026-09-17"), text.replace("N40W074", "N40E074")):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                build_elevation.parse_terrain_catalog(bad)

    def test_the_newest_dated_version_of_each_conterminous_tile_is_listed(self):
        def entry(key, size, etag):
            return (f"<Contents><Key>StagedProducts/Elevation/13/TIFF/historical/{key}</Key>"
                    f"<LastModified>2026-09-17T20:27:03.000Z</LastModified><ETag>&quot;{etag}&quot;</ETag>"
                    f"<Size>{size}</Size><StorageClass>STANDARD</StorageClass></Contents>")

        pages = {
            None: "<ListBucketResult><IsTruncated>true</IsTruncated>"
                  + entry("n41w074/USGS_13_n41w074_20260820.tif", 5, "a" * 32)
                  + entry("n41w074/USGS_13_n41w074_20260917.tif", 6, "b" * 32)
                  + entry("n41w074/USGS_13_n41w074_20260917.xml", 1, "c" * 32)
                  + "<NextContinuationToken>next+page/=</NextContinuationToken></ListBucketResult>",
            "next+page/=": "<ListBucketResult><IsTruncated>false</IsTruncated>"
                           + entry("n61w150/USGS_13_n61w150_20240101.tif", 7, "d" * 32)
                           + entry("n20w156/USGS_13_n20w156_20240101.tif", 8, "e" * 32)
                           + entry("n25w081/USGS_13_n25w081_20220406.tif", 9, "f" * 32 + "-3")
                           + "</ListBucketResult>",
        }
        asked = []

        def fetch(url):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
            asked.append(query)
            return pages[query.get("continuation-token", [None])[0]]

        objects = terrain_catalog.list_bucket(fetch)
        tiles = terrain_catalog.newest_tiles(objects)
        self.assertEqual(tiles, {(-74, 40): ("n41w074", "20260917", 6, "b" * 32),
                                 (-81, 24): ("n25w081", "20220406", 9, "f" * 32 + "-3")})
        # With an area, only the cells that touch it are listed.
        with tempfile.TemporaryDirectory() as tmp:
            path, sha256 = ElevationHybridTests.write_area(Path(tmp) / "area.geojson.gz",
                                                           [(-75, 39), (-73.5, 39), (-73.5, 42), (-75, 42)])
            area = build_elevation.load_area(path, sha256)
            self.assertEqual(list(terrain_catalog.newest_tiles(objects, area=area)), [(-74, 40)])
        self.assertEqual(asked[0]["prefix"], ["StagedProducts/Elevation/13/TIFF/historical/"])
        self.assertEqual(build_elevation.parse_terrain_catalog(build_elevation.format_terrain_catalog(tiles)), tiles)
        with self.assertRaisesRegex(ValueError, "next page"):
            terrain_catalog.parse_listing("<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>")

    def test_the_area_is_the_countrys_polygon_cut_to_the_conterminous_box(self):
        def country(name, level, ring):
            return {"type": "Feature", "properties": {"name": name, "admin_level": level},
                    "geometry": {"type": "Polygon", "coordinates": [[*ring, ring[0]]]}}

        export = {"type": "FeatureCollection", "features": [
            country("United States", "2", [(-170, 20), (-70, 20), (-70, 60), (-170, 60)]),
            country("United States", "4", [(-100, 30), (-90, 30), (-90, 40), (-100, 40)]),
            country("Canada", "2", [(-140, 49), (-60, 49), (-60, 70), (-140, 70)])]}
        from shapely.geometry import shape
        feature = terrain_catalog.area_feature(export, "United States", "a test", terrain_catalog.CONTERMINOUS_BOX)
        self.assertEqual(feature["properties"], {"name": "United States", "source": "a test", "box": [-126, 23, -65, 51]})
        # Without a box the polygon is the whole country.
        whole = terrain_catalog.area_feature(export, "Canada", "a test")
        self.assertEqual(whole["properties"], {"name": "Canada", "source": "a test"})
        self.assertEqual(shape(whole["geometry"]).bounds, (-140.0, 49.0, -60.0, 70.0))
        self.assertEqual(shape(feature["geometry"]).bounds, (-126.0, 23.0, -70.0, 51.0))
        data = terrain_catalog.area_bytes(feature)
        self.assertEqual(data, terrain_catalog.area_bytes(json.loads(json.dumps(feature))))
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "area.geojson.gz").write_bytes(data)
            polygon, prepared = build_elevation.load_area(Path(tmp) / "area.geojson.gz", hashlib.sha256(data).hexdigest())
            self.assertEqual(polygon.bounds, (-126.0, 23.0, -70.0, 51.0))
        for name in ("Mexico", "Canada "):
            with self.assertRaisesRegex(ValueError, "not one"):
                terrain_catalog.area_feature(export, name, "a test")
        export["features"].append(country("Hawaii only", "2", [(-160, 19), (-155, 19), (-155, 22), (-160, 22)]))
        with self.assertRaisesRegex(ValueError, "no valid polygon inside"):
            terrain_catalog.area_feature(export, "Hawaii only", "a test", terrain_catalog.CONTERMINOUS_BOX)


class SonnyCatalogTests(unittest.TestCase):
    """Sonny's area and catalog, on 41-post tiles."""

    POSTS = 41

    def setUp(self):
        for module in (build_elevation, terrain_catalog):
            patcher = patch.object(module, "POSTS", self.POSTS)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_patches_where_sonnys_posts_are_srtms_are_found_and_chance_matches_are_not(self):
        import numpy as np

        rng = np.random.default_rng(3)
        srtm = rng.integers(100, 300, (self.POSTS, self.POSTS)).astype(">i2")
        sonny = (srtm + rng.integers(1, 5, srtm.shape)).astype(">i2")
        # The north-west two by two blocks hold SRTM; one block in the south-east matches by chance.
        block = terrain_catalog.FILL_BLOCK
        sonny[:2 * block, :2 * block] = srtm[:2 * block, :2 * block]
        sonny[3 * block:, 3 * block:] = srtm[3 * block:, 3 * block:]
        # The sea is no evidence either way.
        sonny[:, -1] = srtm[:, -1] = 0
        found = terrain_catalog.srtm_fill_blocks(sonny, srtm, (-9, 41))
        step = build_elevation.STEP
        self.assertEqual(len(found), 2)
        self.assertAlmostEqual(sum(part.area for part in found), 5 * (block * step) ** 2, places=12)
        with patch.object(terrain_catalog, "FILL_MIN_BLOCKS", 4):
            patch_polygon = terrain_catalog.srtm_fill(found)
        # The four blocks, widened by one block; the chance block is left out.
        west, south, east, north = patch_polygon.bounds
        self.assertAlmostEqual(west, -9 - step / 2 - block * step, places=9)
        self.assertAlmostEqual(east, -9 - step / 2 + 3 * block * step, places=9)
        self.assertAlmostEqual(north, 42 + step / 2 + block * step, places=9)
        self.assertFalse(patch_polygon.contains(Point(-9 + 3.5 * block * step, 41 + 0.5 * block * step)))
        self.assertIsNone(terrain_catalog.srtm_fill(found[1:]))

    def test_the_countries_area_is_their_union_cut_and_less_the_patches(self):
        exports = {
            1: {"features": [{"type": "Feature", "properties": {"@type": "relation", "@id": 1, "name": "One"},
                              "geometry": mapping(box(0, 0, 2, 2))},
                             {"type": "Feature", "properties": {"@type": "relation", "@id": 9, "name": "Sub"},
                              "geometry": mapping(box(0, 0, 1, 1))}]},
            2: {"features": [{"type": "Feature", "properties": {"@type": "relation", "@id": 2, "name": "Two"},
                              "geometry": mapping(box(2, 0, 4, 2))},
                             {"type": "Feature", "properties": {"@type": "way", "@id": 2, "name": "Two"},
                              "geometry": mapping(box(2, 0, 3, 1))}]}}
        polygons = {relation: terrain_catalog.relation_polygon(exports[relation], relation) for relation in (1, 2)}
        self.assertEqual(polygons[1][0], "One")
        feature = terrain_catalog.countries_feature(polygons, "test", {2: (2, 0, 3, 2)}, [box(0, 0, 1, 1)], (0, 0, 10, 1.5))
        from shapely.geometry import shape
        area = shape(feature["geometry"])
        self.assertAlmostEqual(area.area, 3 * 1.5 - 1)
        self.assertEqual((feature["properties"]["names"], feature["properties"]["relations"],
                          feature["properties"]["cuts"], feature["properties"]["box"]),
                         (["One", "Two"], [1, 2], {"2": [2, 0, 3, 2]}, [0, 0, 10, 1.5]))
        with self.assertRaisesRegex(ValueError, "0 polygons of relation 3"):
            terrain_catalog.relation_polygon(exports[1], 3)
        with self.assertRaisesRegex(ValueError, "no valid polygon"):
            terrain_catalog.countries_feature(polygons, "test", without=[box(-1, -1, 5, 3)])

    def test_sonnys_folder_page_names_each_cells_file_and_a_download_pins_it(self):
        import numpy as np

        html = (
            '<div class="flip-entry" id="entry-1DWITCiLuCLIkcYQRaItJX5mwSaxGkskK" tabindex="0">'
            '<a href="https://drive.google.com/file/d/1DWITCiLuCLIkcYQRaItJX5mwSaxGkskK/view?usp=drive_web" target="_blank">'
            '<div class="flip-entry-title">N38W010.zip</div></a></div>'
            '<div class="flip-entry" id="entry-0BxphPoRgwhnoMjZYbUhiLXFaTVk" tabindex="0">'
            '<a href="https://drive.google.com/file/d/0BxphPoRgwhnoMjZYbUhiLXFaTVk/view?usp=drive_web&amp;resourcekey=0-yUN8-e7SYxqkNXtDmq8yAg" target="_blank">'
            '<div class="flip-entry-title">N48E013.zip</div></a></div>'
            '<div class="flip-entry" id="entry-1rgGA22Ha42ulQORK9Pfp4JPpPAIKFx6Q" tabindex="0">'
            '<a href="https://drive.google.com/file/d/1rgGA22Ha42ulQORK9Pfp4JPpPAIKFx6Q/view?usp=drive_web" target="_blank">'
            '<div class="flip-entry-title">_Datasources.txt</div></a></div>')
        self.assertEqual(terrain_catalog.sonny_listing(html), {
            (-10, 38): "1DWITCiLuCLIkcYQRaItJX5mwSaxGkskK",
            (13, 48): "0BxphPoRgwhnoMjZYbUhiLXFaTVk/0-yUN8-e7SYxqkNXtDmq8yAg"})
        # Two files of one name leave the cell's tile in doubt.
        twice = html + html.split("</a></div>")[0].replace("1DWITCiLuCLIkcYQRaItJX5mwSaxGkskK",
                                                           "1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") + "</a></div>"
        with self.assertRaisesRegex(ValueError, "lists N38W010.zip twice"):
            terrain_catalog.sonny_listing(twice)
        stream = io.BytesIO()
        heights = np.full((self.POSTS, self.POSTS), 3, dtype=">i2")
        heights[0, 0] = -40
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr("N48E013.hgt", heights.tobytes())
        data = stream.getvalue()
        asked = []

        def fetch(url):
            asked.append(url)
            return data, "Mon, 15 Jul 2024 14:06:34 GMT"

        tile, read = terrain_catalog.sonny_tile((13, 48), "0BxphPoRgwhnoMjZYbUhiLXFaTVk/0-yUN8-e7SYxqkNXtDmq8yAg", fetch)
        self.assertEqual(tile, ("0BxphPoRgwhnoMjZYbUhiLXFaTVk/0-yUN8-e7SYxqkNXtDmq8yAg", "20240715", len(data),
                                hashlib.sha256(data).hexdigest()))
        self.assertEqual(asked, ["https://drive.usercontent.google.com/download?id=0BxphPoRgwhnoMjZYbUhiLXFaTVk"
                                 "&export=download&confirm=t&resourcekey=0-yUN8-e7SYxqkNXtDmq8yAg"])
        self.assertEqual(read["rejectedPixels"], (build_elevation.SONNY_REJECT_MARGIN + 1) ** 2)
        # The pinned line reads back as the source list's catalog does.
        line = build_elevation.format_sonny_catalog({(13, 48): tile})
        self.assertEqual(build_elevation.parse_sonny_catalog(line), {(13, 48): tile})
        with self.assertRaisesRegex(ValueError, "not Sonny's tile of N48E014"):
            terrain_catalog.sonny_tile((14, 48), "1DWITCiLuCLIkcYQRaItJX5mwSaxGkskK", fetch)


class KeptTerrainTests(unittest.TestCase):
    """Terrain kept as HGT tiles in the elevation bucket, and CEDD's tiles of Hong Kong, on 41-post tiles."""

    POSTS = 41
    MIRROR = "gs://bicino-routing-elevation/terrain-sources/cedd-hk-lidar-dtm-2020/"

    def setUp(self):
        for module in (build_elevation, terrain_catalog):
            patcher = patch.object(module, "POSTS", self.POSTS)
            patcher.start()
            self.addCleanup(patcher.stop)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def kept_source(self, tiles, files=None):
        return build_elevation.TerrainSource(
            "cedd-hk-lidar-dtm-2020", build_elevation.CEDD_ORIGIN, tiles, "c" * 64, "https://terms.example",
            "https://credit.example", Path("area.geojson.gz"), "a" * 64, build_elevation.CEDD_ADAPTER, None,
            self.MIRROR, files)

    def kept_tile(self, cell, heights):
        """A tile written as the makers write it; its bytes and the tiles entry that pins it."""
        made = self.root / "made"
        made.mkdir(exist_ok=True)
        build_elevation.write_tile(made, cell, heights)
        data = build_elevation.hgt_path(made, *cell).read_bytes()
        return data, ("p" * 64, "20261127", len(data), hashlib.sha256(data).hexdigest())

    def test_the_kept_catalog_pins_each_tile_and_its_provenance(self):
        tiles = {(114, 22): ("1" * 64, "20261127", 120158, "2" * 64), (113, 22): ("3" * 64, "20261127", 9, "4" * 64)}
        text = build_elevation.format_kept_catalog(tiles)
        self.assertEqual(text, f"N22E113 20261127 9 {'4' * 64} {'3' * 64}\nN22E114 20261127 120158 {'2' * 64} {'1' * 64}\n")
        self.assertEqual(build_elevation.parse_kept_catalog(text), tiles)
        lines = text.splitlines(keepends=True)
        for broken, message in ((lines[1] + lines[0], "not sorted"), (lines[0] + lines[0], "repeats a cell"),
                                (text.replace("N22E113 20261127 9", "N22E113 2026-11-27 9"), "invalid"),
                                (text.replace(" 9 ", " 0 "), "invalid")):
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                build_elevation.parse_kept_catalog(broken)

    def test_a_kept_tile_is_read_from_the_fetched_copy_alone_and_as_pinned(self):
        import numpy as np

        cell = (114, 22)
        heights = np.full((self.POSTS, self.POSTS), 52.0, dtype="float32")
        heights[:5] = np.nan
        data, tile = self.kept_tile(cell, heights)
        files = self.root / "files"
        files.mkdir()
        source = self.kept_source({cell: tile}, files)
        # What the receipt pins: the copy's URL, size and SHA-256, and the rule applied when the tile was made.
        self.assertEqual(source.pin(cell), {
            "source": "cedd-hk-lidar-dtm-2020", "url": f"{self.MIRROR}N22E114.hgt.gz", "bytes": len(data),
            "etag": tile[3], "areaSha256": "a" * 64, "rejects": {"below": -10, "above": 1000, "pixelsAround": 24}})
        self.assertEqual(source.provenance_file(cell), ("N22E114.txt", "p" * 64))
        with self.assertRaisesRegex(ValueError, "N22E114.hgt.gz was not fetched from gs://.*fetch-terrain"):
            build_elevation.read_kept_cell(source, cell, self.root)
        with self.assertRaisesRegex(ValueError, "was not fetched"):
            build_elevation.read_kept_cell(self.kept_source({cell: tile}), cell, self.root)
        (files / "N22E114.hgt.gz").write_bytes(data)
        posts, read = build_elevation.read_kept_cell(source, cell, self.root)
        self.assertEqual(read, {"sha256": tile[3], "readBytes": len(data), "tileDate": "20261127", "via": "mirror"})
        np.testing.assert_array_equal(posts, heights)
        # Another file, or one the catalog pins that is not a tile, stops the cell.
        (files / "N22E114.hgt.gz").write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
        with self.assertRaisesRegex(ValueError, "not the catalog's"):
            build_elevation.read_kept_cell(source, cell, self.root)
        (files / "N22E114.hgt.gz").write_bytes(b"not a tile")
        broken = self.kept_source({cell: ("p" * 64, "20261127", 10, hashlib.sha256(b"not a tile").hexdigest())}, files)
        with self.assertRaisesRegex(ValueError, "is not a gzipped HGT tile"):
            build_elevation.read_kept_cell(broken, cell, self.root)

    def test_a_kept_source_uploads_its_tiles_and_their_provenance_as_pinned(self):
        import numpy as np

        cell = (114, 22)
        data, tile = self.kept_tile(cell, np.full((self.POSTS, self.POSTS), 7.0, dtype="float32"))
        provenance = b"11NE14D(e842n820,e843n821).zip 5 0000\n"
        source = self.kept_source({cell: (hashlib.sha256(provenance).hexdigest(), *tile[1:])})
        files = {"N22E114.hgt.gz": data, "N22E114.txt": provenance}
        uploaded = {}
        done = terrain_catalog.mirror_files(source, {}, lambda cell, name: files[name],
                                            lambda data, url: uploaded.update({url: data}))
        self.assertEqual(done, {"N22E114.hgt.gz": "copied", "N22E114.txt": "copied"})
        self.assertEqual(uploaded, {f"{self.MIRROR}N22E114.hgt.gz": data, f"{self.MIRROR}N22E114.txt": provenance})
        # A provenance file the copy holds is read back and must be the catalog's.
        held = {"N22E114.hgt.gz": len(data), "N22E114.txt": len(provenance)}
        bucket = {f"{self.MIRROR}N22E114.txt": provenance}
        self.assertEqual(terrain_catalog.mirror_files(source, held, None, None, read_held=bucket.get),
                         {"N22E114.hgt.gz": "held", "N22E114.txt": "held"})
        bucket[f"{self.MIRROR}N22E114.txt"] = provenance + b"x"
        for read_held in (bucket.get, None):
            with self.assertRaisesRegex(ValueError, "N22E114.txt is not the provenance file the catalog pins"):
                terrain_catalog.mirror_files(source, held, None, None, read_held=read_held)
        files["N22E114.txt"] = provenance + b"x"
        with self.assertRaisesRegex(ValueError, "N22E114.txt is not the catalog's"):
            terrain_catalog.mirror_files(source, {"N22E114.hgt.gz": len(data)}, lambda cell, name: files[name],
                                         lambda data, url: None)

    def cedd_zip(self, left, top, pixels, crs="EPSG:2326", members=("tile.tif",), nodata=-9999.0):
        """A zip of one 0.5 m GeoTIFF, as CEDD's are."""
        from rasterio.io import MemoryFile
        from rasterio.transform import from_origin

        with MemoryFile() as memory:
            with memory.open(driver="GTiff", width=pixels.shape[1], height=pixels.shape[0], count=1, dtype="float32",
                             crs=crs, transform=from_origin(left, top, 0.5, 0.5), nodata=nodata) as dataset:
                dataset.write(pixels.astype("float32"), 1)
            raster = memory.read()
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            for member in members:
                archive.writestr(member, raster)
        return stream.getvalue()

    def test_a_cedd_zip_is_averaged_to_5_m_leaving_out_pixels_without_data(self):
        import numpy as np

        pixels = np.full((20, 30), 10.0)
        pixels[:10, :10] = -9999.0
        pixels[10:, 10:20] = np.where(np.arange(100).reshape(10, 10) % 2, -9999.0, 30.0)
        pixels[:10, 20:] = np.arange(100).reshape(10, 10)
        means, corner = terrain_catalog.cedd_zip_pixels(self.cedd_zip(842000.0, 820000.0, pixels), "a.zip")
        self.assertEqual(corner, (842000.0, 820000.0))
        np.testing.assert_allclose(means, [[np.nan, 10.0, 49.5], [10.0, 30.0, 10.0]])
        # A corner a fraction of a micrometre off the grid is on it.
        self.assertEqual(terrain_catalog.cedd_zip_pixels(self.cedd_zip(842000.0000000938, 820000.00000001, pixels),
                                                         "a.zip")[1], (842000.0, 820000.0))
        for data, message in ((self.cedd_zip(842000.0, 820000.0, pixels, crs="EPSG:32650"), "HK1980"),
                              (self.cedd_zip(842000.0, 820000.0, pixels, nodata=None), "declares no value"),
                              (self.cedd_zip(842002.5, 820000.0, pixels), "HK1980"),
                              (self.cedd_zip(842000.0, 820000.0, pixels[:, :25]), "HK1980"),
                              (self.cedd_zip(842000.0, 820000.0, pixels, members=("a.tif", "b.tif")), "not one GeoTIFF")):
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                terrain_catalog.cedd_zip_pixels(data, "a.zip")

    def test_cedd_zips_make_a_cells_kept_tile_and_name_every_zip_it_read(self):
        import numpy as np
        from pyproj import Transformer

        cell = (114, 22)
        # Two zips side by side under the cell's first posts, which lie at its north-west corner.
        x, y = Transformer.from_crs(4326, 2326, always_xy=True).transform(114.003, 22.997)
        left, top = round(x / 5) * 5 - 200, round(y / 5) * 5 + 200
        west = np.full((800, 400), 50.0)
        east = np.full((800, 400), 80.0)
        east[600:, 300:] = -60.0  # a pit, which is not ground
        zips = {"west.zip": self.cedd_zip(left, top, west), "east.zip": self.cedd_zip(left + 200, top, east)}
        area_path = self.root / "area.geojson.gz"
        area_path.write_bytes(terrain_catalog.area_bytes(
            {"type": "Feature", "properties": {}, "geometry": mapping(box(113.9, 22.2, 114.5, 23.0))}))
        area = build_elevation.load_area(area_path, hashlib.sha256(area_path.read_bytes()).hexdigest())
        out = self.root / "cells"
        records = terrain_catalog.cedd_cells([(name, f"https://cedd.example/{name}") for name in sorted(zips)], area,
                                             out, lambda url: zips[url.rpartition("/")[2]], jobs=2,
                                             log=lambda line: None)
        self.assertEqual([record["cell"] for record in records], ["N22E114"])
        record = records[0]
        posts, _ = build_elevation.read_tile(build_elevation.hgt_path(out, *cell))
        found = np.unique(posts[np.isfinite(posts)].round(1))
        self.assertIn(50.0, found)
        self.assertIn(80.0, found)
        self.assertGreater(record["rejectedPixels"], 0)
        self.assertEqual(record["rejectedHeights"], [-60.0, -60.0])
        self.assertTrue(np.isnan(posts).any())
        self.assertEqual((out / "provenance" / "N22E114.txt").read_text(), "".join(
            f"{name} {len(zips[name])} {hashlib.sha256(zips[name]).hexdigest()}\n" for name in sorted(zips)))
        # The catalog of what was made pins the tile and its provenance.
        text = terrain_catalog.kept_catalog(out, "20261127")
        # A zip that is not CEDD's layout stops the run, which names every such zip after reading them all.
        zips["bad.zip"] = self.cedd_zip(left, top, west[:, :395])
        with self.assertRaisesRegex(ValueError, r"^1 zips refused: bad.zip is not a 0.5 m GeoTIFF"):
            terrain_catalog.cedd_cells([(name, name) for name in sorted(zips)], area, self.root / "again",
                                       lambda url: zips[url], log=lambda line: None)
        self.assertEqual(build_elevation.parse_kept_catalog(text), {cell: (
            hashlib.sha256((out / "provenance" / "N22E114.txt").read_bytes()).hexdigest(), "20261127",
            record["fileBytes"], hashlib.sha256(build_elevation.hgt_path(out, *cell).read_bytes()).hexdigest())})


class GsiTileTests(unittest.TestCase):
    """GSI's PNG tiles of Japan into a kept tile, on 41-post tiles and a small area."""

    POSTS = 41

    def setUp(self):
        for module in (build_elevation, terrain_catalog):
            patcher = patch.object(module, "POSTS", self.POSTS)
            patcher.start()
            self.addCleanup(patcher.stop)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    @staticmethod
    def png(centimetres):
        """An RGB PNG whose pixels encode heights in centimetres as GSI's do; NaN is none."""
        import struct
        import zlib

        import numpy as np

        value = np.where(np.isnan(centimetres), 2 ** 23, np.nan_to_num(centimetres)).astype(np.int64) % 2 ** 24
        pixels = np.stack([value >> 16, (value >> 8) & 255, value & 255], axis=-1).astype(np.uint8)
        raw = b"".join(b"\x00" + row.tobytes() for row in pixels)

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

        height, width = centimetres.shape
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

    def test_a_gsi_tile_decodes_to_metres_with_none_and_heights_below_zero(self):
        import numpy as np

        centimetres = np.full((256, 256), 4321.0)
        centimetres[0, :3] = [np.nan, -1, -1050]
        heights = terrain_catalog.gsi_decode(self.png(centimetres))
        self.assertTrue(np.isnan(heights[0, 0]))
        np.testing.assert_allclose(heights[0, 1:4], [-0.01, -10.5, 43.21], rtol=0, atol=1e-4)
        with self.assertRaisesRegex(ValueError, "not a 256-pixel RGB PNG"):
            terrain_catalog.gsi_decode(self.png(centimetres[:16, :16]))

    def test_dem5a_gives_the_pixels_it_has_and_dem10b_the_rest_and_the_sea_costs_one_request(self):
        import numpy as np

        lidar = np.full((256, 256), 4500.0)
        lidar[:, :128] = np.nan
        served = {"dem_png/14/1/2": (self.png(np.full((256, 256), 3000.0)), "e10b"),
                  "dem5a_png/14/1/2": (self.png(lidar), "e5a")}
        asked = []

        def fetch(url):
            asked.append(url.rpartition("/xyz/")[2][:-4])
            return served.get(asked[-1])

        heights, read = terrain_catalog.gsi_tile(1, 2, fetch)
        self.assertEqual(read, [("dem_png", "e10b"), ("dem5a_png", "e5a")])
        np.testing.assert_allclose(heights[:, :128], 30.0)
        np.testing.assert_allclose(heights[:, 128:], 45.0)
        asked.clear()
        self.assertEqual(terrain_catalog.gsi_tile(1, 3, fetch), (None, []))
        self.assertEqual(asked, ["dem_png/14/1/3"])

    def test_gsi_tiles_make_a_cells_kept_tile_once_and_name_every_tile_read(self):
        import numpy as np

        cell = (139, 35)
        area_path = self.root / "area.geojson.gz"
        area_path.write_bytes(terrain_catalog.area_bytes(
            {"type": "Feature", "properties": {}, "geometry": mapping(box(139.0, 35.985, 139.02, 36.0))}))
        area = build_elevation.load_area(area_path, hashlib.sha256(area_path.read_bytes()).hexdigest())
        pit = np.full((256, 256), 4500.0)
        pit[100:103, 100:103] = -5000.0
        pitted = (terrain_catalog.gsi_tile_x(139.0), terrain_catalog.gsi_tile_y(35.99))
        asked = []

        def fetch(url):
            asked.append(url)
            layer, _, x, y = url.rpartition("/xyz/")[2][:-4].split("/")
            if layer == "dem5a_png":
                # DEM5A has the column of tiles the posts lie in, and not the next.
                if int(x) % 2:
                    return None
                return self.png(pit if (int(x), int(y)) == pitted else np.full((256, 256), 4500.0)), f"a{x}"
            return self.png(np.full((256, 256), 3000.0)), f"b{x}.{y}"

        out = self.root / "cells"
        rules = terrain_catalog.gsi_rules(hashlib.sha256(area_path.read_bytes()).hexdigest())
        record = terrain_catalog.gsi_cell(cell, area, out, fetch, rules, jobs=2)
        self.assertEqual(record["tiles"] * 2, len(asked))
        self.assertGreater(record["rejectedPixels"], 9)
        self.assertEqual(record["rejectedHeights"], [-50.0, -50.0])
        posts, _ = build_elevation.read_tile(build_elevation.hgt_path(out, *cell))
        # The posts lie in the column of tiles DEM5A has.
        self.assertEqual(np.unique(posts[np.isfinite(posts)].round(1)).tolist(), [45.0])
        lines = (out / "provenance" / "N35E139.txt").read_text().splitlines()
        self.assertEqual(lines, sorted(lines))
        self.assertEqual(len(lines), len(asked) - sum(int(url.split("/")[-2]) % 2 for url in asked
                                                       if "dem5a_png" in url))
        self.assertTrue(all(re.fullmatch(r"(dem_png|dem5a_png)/14/\d+/\d+ [ab][\d.]+", line) for line in lines))
        # A recorded cell is not made again, unless it was made with other rules: then the run stops.
        self.assertEqual(terrain_catalog.gsi_cell(cell, area, out, None, rules), record)
        for other in (terrain_catalog.gsi_rules("0" * 64), {**rules, "pixelsAround": 4},
                      {**rules, "layers": ["dem_png"]}):
            with self.subTest(other=other), self.assertRaisesRegex(ValueError, "make the cells in a new directory"):
                terrain_catalog.gsi_cell(cell, area, out, None, other)
        self.assertEqual(build_elevation.parse_kept_catalog(terrain_catalog.kept_catalog(out, "20261127"))[cell][2:],
                         (record["fileBytes"], record["fileSha256"]))


    def test_every_gsi_request_waits_its_turn_and_a_429_holds_every_worker(self):
        import http.client
        import urllib.error

        class Rate:
            def __init__(self):
                self.calls = []

            def wait(self):
                self.calls.append("wait")

            def hold(self, seconds):
                self.calls.append(("hold", seconds))

        class Response(io.BytesIO):
            def __init__(self, data, length):
                super().__init__(data)
                self.headers = {"Content-Length": str(length), "ETag": '"e1"'}

        def busy(after):
            return urllib.error.HTTPError("u", 429, "busy", {"Retry-After": after}, None)

        def run(*answers):
            rate, left, slept = Rate(), list(answers), []

            def urlopen(request, timeout):
                answer = left.pop(0)
                if isinstance(answer, Exception):
                    raise answer
                return answer

            with patch.object(terrain_catalog.urllib.request, "urlopen", urlopen), \
                    patch("time.sleep", slept.append):
                found = terrain_catalog.gsi_fetch("https://x/dem_png/14/1/2.png", rate)
            return found, rate.calls, slept

        dropped = http.client.IncompleteRead(b"12", 2)
        found, calls, slept = run(busy("30"), dropped, urllib.error.URLError("reset"), Response(b"tile", 4))
        self.assertEqual(found, (b"tile", "e1"))
        # Four attempts, each through the limiter; the 429 holds everyone for the server's 30 s.
        self.assertEqual(calls, ["wait", ("hold", 30), "wait", "wait", "wait"])
        self.assertEqual(slept, [30, 4, 8])
        # A Retry-After that is no number of seconds, or too long, falls back to the backoff or 5 minutes.
        self.assertEqual(run(busy("Fri, 27 Nov 2026 12:00:00 GMT"), Response(b"t", 1))[1][1], ("hold", 2))
        self.assertEqual(run(busy("3600"), Response(b"t", 1))[1][1], ("hold", 300))
        # The sea is a 404, not an error; a 403 stops the run.
        self.assertEqual(run(urllib.error.HTTPError("u", 404, "none", {}, None))[0], None)
        with self.assertRaises(urllib.error.HTTPError):
            run(urllib.error.HTTPError("u", 403, "no", {}, None))
        with self.assertRaises(http.client.IncompleteRead):
            run(*[dropped] * 6)


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
            self.assertIsNone(identity["method"])
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


class BridgeRuleTests(unittest.TestCase):
    LUA = (b"bridge = {\n[\"yes\"] = \"true\",\n[\"no\"] = \"false\"\n}\nfunction ways_proc (kv, nokeys)\n"
           + graph_lua.BRIDGE_RULE + b"  return 0, kv\nend\n")

    def test_the_images_rules_are_written_out_with_every_bridge_a_bridge(self):
        binary = b"\x7fELF\0other strings\0" + self.LUA + b"\0more\0"
        pinned = hashlib.sha256(self.LUA).hexdigest()
        self.assertEqual(graph_lua.embedded_lua(binary), self.LUA)
        changed = graph_lua.all_bridges_lua(binary, pinned)
        self.assertEqual(changed.count(graph_lua.ALL_BRIDGES_RULE), 1)
        self.assertEqual(changed.replace(graph_lua.ALL_BRIDGES_RULE, graph_lua.BRIDGE_RULE), self.LUA)
        # Rules of another image, with or without the line, stop the build.
        with self.assertRaisesRegex(ValueError, "this change was written for"):
            graph_lua.all_bridges_lua(binary)
        with self.assertRaisesRegex(ValueError, "no graph.lua"):
            graph_lua.all_bridges_lua(b"\0bridge = {}\0", pinned)
        twice = b"\0" + self.LUA + graph_lua.BRIDGE_RULE + b"\0"
        with self.assertRaisesRegex(ValueError, "more than once"):
            graph_lua.all_bridges_lua(twice, hashlib.sha256(twice[1:-1]).hexdigest())
        # yes, 1 and no keep the table's answer. Any other value that is present becomes a bridge,
        # unless it is false or 0.
        self.assertEqual(graph_lua.ALL_BRIDGES_RULE, b'  kv["bridge"] = bridge[kv["bridge"]] or (kv["bridge"] and '
                         b'kv["bridge"] ~= "false" and kv["bridge"] ~= "0" and "true") or "false"\n')

    def test_all_bridges_builds_with_the_changed_rules_and_records_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            calls = []

            def run_valhalla(work, script, threads, log_name, volumes):
                calls.append((script, volumes))
                if "graph_lua.py" in script:
                    (work / "graph.lua").write_bytes(b"rules")
                with sqlite3.connect(work / "admin.sqlite") as database:
                    database.execute("CREATE TABLE IF NOT EXISTS admins (name TEXT)")
                    database.execute("INSERT INTO admins VALUES ('United States')")
                used = "[INFO] Using LUA script: /work/graph.lua\n" if "graph_lua.py" in script else ""
                return work / "valhalla-build.log", used

            with patch("build_graph.run_valhalla", run_valhalla):
                valhalla_build(work, Path("admin.osm.pbf"), Path("roads.osm.pbf"), 4)
                valhalla_build(work, Path("admin.osm.pbf"), Path("roads.osm.pbf"), 4, None, True)
            plain, changed = calls
            self.assertNotIn("graph-lua", plain[0])
            self.assertEqual([target for _, target in plain[1]], ["/input/admin.osm.pbf", "/input/roads.osm.pbf"])
            self.assertTrue(changed[0].startswith(
                "python3 /tools/graph_lua.py /usr/local/bin/valhalla_build_tiles /work/graph.lua\n"))
            self.assertIn("--additional-data-elevation /elevation --mjolnir-graph-lua-name /work/graph.lua >",
                          changed[0])
            self.assertIn((Path(graph_lua.__file__).resolve(), "/tools/graph_lua.py"), changed[1])
            identity = graph_lua_identity(work)
            self.assertEqual((identity["baseSha256"], identity["sha256"], identity["bytes"]),
                             (graph_lua.GRAPH_LUA_SHA256, hashlib.sha256(b"rules").hexdigest(), 5))
            # A build whose log does not show Valhalla reading the changed rules is not passed off as one.
            with patch("build_graph.run_valhalla", lambda work, *rest: (work / "valhalla-build.log", "")), \
                    self.assertRaisesRegex(ValueError, "changed tagging rules"):
                valhalla_build(work, Path("admin.osm.pbf"), Path("roads.osm.pbf"), 4, None, True)


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


UNGRADED = "http://ungraded:8002"


class FakeGradedValhalla:
    """/route, /trace_attributes and /height of an ungraded and a graded graph.

    A graded graph can add a detour to every route (`detour`) and report steep
    edges everywhere (`steep`). In the hilly city (south of 50 degrees) its
    routes are steep, except that with use_hills 0 it takes a flatter route
    through an extra point (`avoids_hills`). /height gives that route 10 m of
    climb and every other route 30 m.
    """

    def __init__(self, *, detour=0.0, steep=False, avoids_hills=True, ungraded_avoids_hills=False, broken=()):
        self.detour, self.steep = detour, steep
        self.avoids_hills, self.ungraded_avoids_hills = avoids_hills, ungraded_avoids_hills
        self.broken = broken  # paths the graded graph answers with HTTP 400
        self.flatter = set()

    def __call__(self, origin, path, body):
        graded = origin != UNGRADED
        if graded and path in self.broken:
            return 400, {"error_code": 171}
        if path == "/route":
            start, end = body["locations"]
            points = [(round(start["lat"] * 1e6), round(start["lon"] * 1e6)),
                      (round(end["lat"] * 1e6), round(end["lon"] * 1e6))]
            length = 3.0
            if graded and self.detour:
                points.insert(1, (points[0][0] + 500, points[0][1] - 500))
                length *= 1 + self.detour
            avoids = self.avoids_hills if graded else self.ungraded_avoids_hills
            if avoids and body["costing_options"]["bicycle"]["use_hills"] == 0.0:
                points.insert(1, (points[0][0] - 700, points[0][1] + 700))
                length += 0.4
                self.flatter.add(encode_polyline6(points))
            return 200, {"trip": {"summary": {"length": length, "time": 600},
                                  "legs": [{"shape": encode_polyline6(points)}]}}
        if path == "/trace_attributes":
            shape = body["encoded_polyline"]
            hilly = compare_elevation.decode_polyline6(shape)[0][0] < 50 and shape not in self.flatter
            grade = 8 if graded and (self.steep or hilly) else 2
            return 200, {"edges": [
                {"length": 1.0, "max_upward_grade": grade, "max_downward_grade": -1, "weighted_grade": 1.0},
                {"length": 3.0, "max_upward_grade": 1, "max_downward_grade": -2, "weighted_grade": -1.0},
            ]}
        if path == "/height":
            shape = encode_polyline6([(round(p["lat"] * 1e6), round(p["lon"] * 1e6)) for p in body["shape"]])
            return 200, {"height": [0, 4, 10] if shape in self.flatter else [0, 2, 1, 30]}
        return 404, {"error_code": 106}


class ElevationComparisonTests(unittest.TestCase):
    CITIES = [
        {"city": "Flatville", "terrain": "flat", "bbox": [4.8, 52.3, 4.95, 52.4],
         "legs": [{"name": "Across", "origin": [52.3791, 4.9003], "destination": [52.3580, 4.8686]}]},
        {"city": "Hilltown", "terrain": "hilly", "bbox": [8.5, 47.3, 8.6, 47.4],
         "legs": [{"name": "Up", "origin": [47.3779, 8.5403], "destination": [47.3700, 8.5170]}]},
    ]

    def compare(self, **fake):
        valhalla = FakeGradedValhalla(**fake)
        report = compare_elevation.run(valhalla, self.CITIES, UNGRADED, {"candidate": "http://graded:8002"})
        return report, compare_elevation.summarize([report])

    def test_route_bodies_are_the_backends_with_only_use_hills_changed(self):
        from map_platform.bicycle_route_service import PROFILES

        leg = self.CITIES[0]["legs"][0]
        for profile in ("road", "everyday"):
            body = compare_elevation.route_body(leg, profile)
            self.assertEqual(body["costing"], "bicycle")
            self.assertEqual(body["costing_options"]["bicycle"], dict(PROFILES[profile]))
            self.assertEqual([body["locations"][0]["lat"], body["locations"][1]["lon"]], [52.3791, 4.8686])
        hills = compare_elevation.route_body(leg, "everyday", 1.0)
        hills["costing_options"]["bicycle"]["use_hills"] = PROFILES["everyday"]["use_hills"]
        self.assertEqual(hills, compare_elevation.route_body(leg, "everyday"))

    def test_steep_share_counts_edges_steep_either_way_by_length(self):
        edges = [{"length": 1.0, "max_upward_grade": 6, "max_downward_grade": 0, "weighted_grade": 3.0},
                 {"length": 2.0, "max_upward_grade": 1, "max_downward_grade": -7, "weighted_grade": -1.5},
                 {"length": 1.0, "max_upward_grade": 5, "max_downward_grade": -5, "weighted_grade": 0.0}]
        self.assertEqual(compare_elevation.steep_share(edges), {"share": 0.75, "meanAbsWeightedGrade": 1.5})
        self.assertEqual(compare_elevation.steep_share([])["share"], None)

    def test_polyline_decoding_matches_valhalla_precision(self):
        points = [(52_379_100, 4_900_300), (52_358_000, 4_868_600), (-41_285_500, 174_776_200)]
        self.assertEqual(compare_elevation.decode_polyline6(encode_polyline6(points)),
                         [(52.3791, 4.9003), (52.358, 4.8686), (-41.2855, 174.7762)])

    def test_a_source_that_keeps_flat_routes_and_avoids_hills_meets_the_targets(self):
        report, (table, failures) = self.compare()
        self.assertEqual(failures, {"candidate": []})
        flat = report["rows"][0]["profiles"]["everyday"]["sources"]["candidate"]
        self.assertEqual((flat["lengthChange"], flat["sameRoute"], flat["grades"]["share"]), (0.0, True, 0.0))
        hills = report["rows"][1]["hills"]
        self.assertTrue(hills["candidate"]["differs"])
        self.assertEqual(hills["candidate"]["measures"], {"candidate": {"steepShare": [0.0, 0.25], "climb": [10.0, 30.0]}})
        self.assertEqual((hills["ungraded"]["differs"], hills["ungraded"]["measures"]), (False, {}))
        hilltown = next(entry for entry in table if entry["city"] == "Hilltown")
        self.assertEqual((hilltown["hillLegsChanged"], hilltown["hillLegsWorse"], hilltown["medianClimbSaved"],
                          hilltown["medianSteepShareSaved"]), (1, 0, 20.0, 0.25))
        self.assertIn("| candidate | Hilltown | 2 |", compare_elevation.format_table(table))

    def test_detours_and_fake_hills_in_flat_cities_miss_the_targets(self):
        _, (table, failures) = self.compare(detour=0.1, steep=True)
        # Where every street reads as steep, avoiding hills cannot find a gentler route either.
        self.assertEqual(failures["candidate"], [
            "flat median length change +10.0%",
            "2 flat routes are detours around steep readings, the longest Flatville, Across, road: +10.0%, "
            "25% of the direct route at 6%+",
            "flat median 6%+ share 25%",
            "avoiding hills did not lower the 6%+ share (median +0 pts on the mean of all heights)"])
        flatville = next(entry for entry in table if entry["city"] == "Flatville")
        self.assertEqual((flatville["detours"], flatville["swaps"]), (2, 0))
        self.assertNotIn("detours", next(entry for entry in table if entry["city"] == "Hilltown"))

    @staticmethod
    def flat_report(routes):
        """One flat city with a Road route per (length change, 6%+ share of the direct route)."""
        rows = []
        for index, (change, share) in enumerate(routes):
            direct = {"share": None, "error": "400/171"} if share is None else {"share": share,
                                                                                 "meanAbsWeightedGrade": 0.5}
            result = {"km": round(3 * (1 + change), 3), "minutes": 10.0, "lengthChange": change,
                      "sameRoute": change == 0, "grades": {"share": 0.0, "meanAbsWeightedGrade": 0.2},
                      "ungradedRouteGrades": direct}
            rows.append({"city": "Flatville", "terrain": "flat", "leg": f"Leg {index}", "profiles": {
                "road": {"ungraded": {"km": 3.0, "minutes": 10.0}, "sources": {"candidate": result}}}})
        return {"schema": "bicino-elevation-comparison-v1", "sources": ["candidate"], "rows": rows}

    def test_a_longer_flat_route_is_a_detour_only_where_the_direct_route_reads_steep(self):
        quiet = [(0.0, 0.0)] * 39
        report = self.flat_report([*quiet, (0.1, 0.01)])
        table, failures = compare_elevation.summarize([report])
        self.assertEqual(failures, {"candidate": []})  # a swap: listed, not missed
        self.assertEqual((table[0]["detours"], table[0]["swaps"], table[0]["maximumLengthChange"]), (0, 1, 0.1))
        self.assertEqual(compare_elevation.long_flat_routes(report["rows"], "candidate"), [
            {"source": "candidate", "city": "Flatville", "leg": "Leg 39", "profile": "road",
             "lengthChange": 0.1, "directSteepShare": 0.01, "verdict": "swap"}])
        self.assertIn("| candidate | Flatville | 40 | 0.0% | +10.0% | 0, 1 |", compare_elevation.format_table(table))

        _, failures = compare_elevation.summarize([self.flat_report([*quiet, (0.2, 0.06)])])
        self.assertEqual(failures["candidate"], [
            "1 flat route is a detour around steep readings, the longest Flatville, Leg 39, road: +20.0%, "
            "6% of the direct route at 6%+"])
        # Exactly at a limit is neither long, steep nor a large swap.
        _, failures = compare_elevation.summarize([self.flat_report([*quiet, (0.05, 0.9), (0.15, 0.05)])])
        self.assertEqual(failures, {"candidate": []})

    def test_an_unread_direct_route_cannot_turn_a_detour_into_a_swap(self):
        _, failures = compare_elevation.summarize([self.flat_report([*[(0.0, 0.0)] * 39, (0.2, None)])])
        self.assertEqual(failures["candidate"], [
            "1 grade lookups failed",
            "1 flat route is a detour around steep readings, the longest Flatville, Leg 39, road: +20.0%, "
            "direct route's grades unread"])

    def test_swaps_miss_the_targets_only_when_they_are_many(self):
        swaps = [(0.1, 0.0), (0.12, 0.02)]
        _, failures = compare_elevation.summarize([self.flat_report([*[(0.0, 0.0)] * 38, *swaps])])
        self.assertEqual(failures["candidate"], ["2 of 40 flat routes are more than 5% longer without steep readings"])
        _, failures = compare_elevation.summarize([self.flat_report([*[(0.0, 0.0)] * 98, *swaps])])
        self.assertEqual(failures, {"candidate": []})  # 2 of 100 is within 3%
        _, failures = compare_elevation.summarize([self.flat_report([(0.0, 0.0), (0.0, 0.0), (0.1, 0.0)])])
        self.assertEqual(failures, {"candidate": []})  # one small swap is only listed, however few the routes

    def test_one_large_swap_misses_the_targets(self):
        _, failures = compare_elevation.summarize([self.flat_report([*[(0.0, 0.0)] * 99, (0.2, 0.0)])])
        self.assertEqual(failures["candidate"], [
            "1 flat route is more than 15% longer without steep readings, the longest Flatville, Leg 99, road: "
            "+20.0%, 0% of the direct route at 6%+"])

    def test_a_source_that_ignores_hills_misses_the_targets(self):
        _, (_, failures) = self.compare(avoids_hills=False)
        self.assertEqual(failures["candidate"], ["use_hills changed 0 of 1 hilly legs"])

    def test_hill_avoidance_is_judged_on_the_referee_heights(self):
        def report(name, measures):
            hills = {"differs": True, "km": [3.4, 3.0], "measures": measures}
            row = {"city": "Hilltown", "terrain": "hilly", "leg": "Up", "profiles": {},
                   "hills": {"ungraded": {"differs": False, "measures": {}}, name: hills}}
            return {"schema": "bicino-elevation-comparison-v1", "sources": [name], "rows": [row]}

        gentler = {"steepShare": [0.1, 0.3], "climb": [70.0, 60.0]}  # climbs more, but gently
        steeper = {"steepShare": [0.35, 0.3], "climb": [40.0, 60.0]}
        candidate = report("candidate", {"candidate": gentler, "bare": steeper})
        table, failures = compare_elevation.summarize([candidate])
        self.assertEqual(failures, {"candidate": []})  # the mean over both graphs is still gentler
        self.assertEqual((table[0]["medianClimbSaved"], table[0]["medianSteepShareSaved"]), (5.0, 0.075))
        table, failures = compare_elevation.summarize([candidate], referee="bare")
        self.assertEqual(failures, {"candidate": ["avoiding hills did not lower the 6%+ share (median -5 pts on bare)"]})
        self.assertEqual(table[0]["hillLegsWorse"], 1)
        _, failures = compare_elevation.summarize([report("candidate", {"candidate": steeper})])
        self.assertEqual(len(failures["candidate"]), 1)

    def test_failed_measurements_are_missed_targets(self):
        _, (table, failures) = self.compare(broken=("/route",))
        self.assertEqual(failures["candidate"], ["4 routes failed on the graded or ungraded graph",
                                                 "1 hilly legs failed to route", "use_hills changed 0 of 1 hilly legs"])
        self.assertEqual([entry["errors"] for entry in table], [2, 3])
        _, (_, failures) = self.compare(broken=("/trace_attributes",))
        self.assertEqual(failures["candidate"][0], "8 grade lookups failed")
        self.assertIn("1 changed hilly legs have no 6%+ share on any graded graph", failures["candidate"])

    def test_hill_avoidance_is_judged_without_height(self):
        report, (table, failures) = self.compare(broken=("/height",))
        self.assertEqual(failures, {"candidate": []})
        self.assertEqual(report["rows"][1]["hills"]["candidate"]["measures"]["candidate"]["climb"], [None, None])
        hilltown = next(entry for entry in table if entry["city"] == "Hilltown")
        self.assertEqual((hilltown["medianSteepShareSaved"], hilltown["medianClimbSaved"]), (0.25, None))

    def test_climb_ignores_rises_below_the_hysteresis(self):
        self.assertEqual(compare_elevation.total_climb([10, 12, 10, 12, 10, 12]), 0.0)
        self.assertEqual(compare_elevation.total_climb([10, 11, 12, 13, 14, 9, 15]), 9.0)  # 3 m to 13, 6 m from 9
        self.assertEqual(compare_elevation.total_climb([10, 12, 10, 12], hysteresis=1), 4.0)

    def test_report_only_cities_are_tabulated_but_never_judged(self):
        towers = {**self.CITIES[0], "city": "Towertown", "reportOnly": True}
        slopes = {**self.CITIES[1], "city": "Slopeville", "reportOnly": True}
        valhalla = FakeGradedValhalla()
        report = compare_elevation.run(valhalla, [*self.CITIES, towers, slopes], UNGRADED,
                                       {"candidate": "http://graded:8002"})
        self.assertEqual([row.get("reportOnly", False) for row in report["rows"]], [False, False, True, True])
        # A detour, a failed route and a broken hilly leg in report-only cities change no verdict.
        flat = report["rows"][2]["profiles"]
        flat["everyday"]["sources"]["candidate"]["lengthChange"] = 0.3
        flat["road"]["sources"]["candidate"] = {"error": "400/442"}
        report["rows"][3]["hills"]["candidate"] = {"differs": None, "error": "400/442"}
        report["rows"][3]["hills"]["ungraded"]["differs"] = True
        table, failures = compare_elevation.summarize([report])
        self.assertEqual(failures, {"candidate": []})
        towertown = next(entry for entry in table if entry["city"] == "Towertown")
        self.assertEqual((towertown["reportOnly"], towertown["maximumLengthChange"], towertown["errors"]), (True, 0.3, 1))
        self.assertEqual(next(entry for entry in table if entry["city"] == "Slopeville")["errors"], 1)
        self.assertNotIn("reportOnly", next(entry for entry in table if entry["city"] == "Flatville"))
        self.assertIn("| candidate | Towertown (report only) | 1 (1 failed) |", compare_elevation.format_table(table))

    def test_use_hills_changing_an_ungraded_route_marks_the_comparison_broken(self):
        _, (_, failures) = self.compare(ungraded_avoids_hills=True)
        self.assertEqual(failures["ungraded"], ["use_hills changed 1 hilly legs without elevation"])

    def test_graded_origins_need_unique_names(self):
        self.assertEqual(compare_elevation.parse_graded(["a=http://x:1", "b=http://y:2"]),
                         {"a": "http://x:1", "b": "http://y:2"})
        for bad in (["a"], ["a=ftp://x"], ["a=http://x", "a=http://y"], ["ungraded=http://x"]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                compare_elevation.parse_graded(bad)

    def test_checked_in_cities_are_well_formed(self):
        cities = json.loads(Path(compare_elevation.__file__).with_name("elevation-probes.json").read_text())
        self.assertEqual({city["terrain"] for city in cities}, {"flat", "hilly"})
        self.assertEqual(len({city["city"] for city in cities}), len(cities))
        for city in cities:
            self.assertLessEqual({"city", "terrain", "bbox", "legs"}, set(city))
            self.assertLessEqual(set(city), {"city", "terrain", "bbox", "legs", "planetOnly", "reportOnly",
                                             "extract", "adminWays", "adminRelations"})
            west, south, east, north = city["bbox"]
            self.assertTrue(west < east and south < north, city["city"])
            self.assertGreaterEqual(len(city["legs"]), 1, city["city"])
            for leg in city["legs"]:
                for latitude, longitude in (leg["origin"], leg["destination"]):
                    self.assertTrue(west < longitude < east and south < latitude < north, leg["name"])
                compare_elevation.route_body(leg, "road")


class SampleElevationTests(unittest.TestCase):
    def test_opening_removes_narrow_bumps_and_keeps_broad_slopes(self):
        import numpy as np

        rows = np.mgrid[0:60, 0:60][0]
        slope = (rows * 1.5).astype("float32")
        heights = slope.copy()
        heights[30:33, 30:33] += 20
        heights[10, 50] = np.nan
        opened = sample_elevation.open_heights(heights, 100, 47)
        inside = (slice(8, 52), slice(8, 52))
        residual = (opened - slope)[inside]
        # The 20 m bump drops to at most one post of the slope; the ramp elsewhere is kept.
        self.assertLessEqual(float(np.nanmax(np.abs(residual))), 1.5)
        self.assertEqual(int(np.count_nonzero(residual[np.isfinite(residual)])), 9)
        self.assertTrue(np.isnan(opened[10, 50]))
        self.assertEqual(sample_elevation.footprint(100, 60).shape, (7, 13))

    def test_mosaic_and_cut_share_border_posts(self):
        import numpy as np

        cells = {(8, 47): 1.0, (9, 47): 2.0, (8, 48): 3.0}
        array, west, north = sample_elevation.mosaic(
            list(cells), lambda cell: np.full((build_elevation.POSTS,) * 2, cells[cell], dtype="float32"))
        self.assertEqual((array.shape, west, north), ((7201, 7201), 8, 49))
        for cell, value in cells.items():
            piece = sample_elevation.cut(array, west, north, cell)
            self.assertEqual(piece.shape, (build_elevation.POSTS,) * 2)
            self.assertEqual(float(piece[1800, 1800]), value)
        empty = sample_elevation.cut(array, west, north, (9, 48))
        # Only its west column and south row, shared with built neighbours, have heights.
        self.assertTrue(np.isnan(empty[:-1, 1:]).all())
        self.assertEqual((float(empty[0, 0]), float(empty[-1, -1])), (3.0, 2.0))

    def test_cog_pixels_centred_on_whole_arcseconds_land_on_posts_unchanged(self):
        import numpy as np
        import rasterio
        from affine import Affine
        from rasterio.io import MemoryFile

        step = build_elevation.STEP
        # Like GEDTM30: pixel edges half a pixel off whole arc-seconds.
        transform = Affine(step, 0, 7.99875, 0, -step, 48.00125)
        size = 3609
        pixels = np.random.default_rng(1).uniform(400, 500, (size, size)).astype("float32")
        pixels[100, 200] = -3.4e38
        with MemoryFile() as memory:
            with memory.open(driver="GTiff", width=size, height=size, count=1, dtype="float32",
                             crs="EPSG:4326", transform=transform, nodata=-3.4e38) as dataset:
                dataset.write(pixels, 1)
            with memory.open() as dataset, rasterio.Env():
                posts = sample_elevation.cog_cell(dataset, (8, 47))
        offset = 4  # 0.00125 degrees = 4.5 pixels, so post 0 is pixel 4
        expected = pixels[offset:offset + 3601, offset:offset + 3601].copy()
        expected[96, 196] = np.nan  # the no-data pixel stays a single no-data post
        np.testing.assert_allclose(posts, expected, atol=1e-3)

    FIRST_POST = 1750

    @classmethod
    def fine_tile(cls, pixels, crs="EPSG:4269"):
        """A GeoTIFF on the 3DEP 1/3 arc-second grid of cell N40W074.

        It holds only the pixels around the middle of the cell: post
        (FIRST_POST, FIRST_POST) lies on the pixel corner (6, 6), as the
        cell's first post does in a whole tile with its six pixels of overlap.
        """
        from affine import Affine
        from rasterio.io import MemoryFile

        fine = build_elevation.STEP / 3
        shift = (3 * cls.FIRST_POST - 6) * fine
        memory = MemoryFile()
        with memory.open(driver="GTiff", width=pixels.shape[1], height=pixels.shape[0], count=1, dtype="float32",
                         crs=crs, transform=Affine(fine, 0, -74 + shift, 0, -fine, 41 - shift),
                         nodata=-999999) as dataset:
            dataset.write(pixels, 1)
        return memory

    def test_tiles_average_a_finer_grid_onto_the_posts(self):
        import numpy as np
        import rasterio

        first = self.FIRST_POST
        rows, columns = np.mgrid[0:300, 0:300]
        # A plane over the pixel centres; post (first + r, first + c) lies on the pixel corner 6 + 3r, 6 + 3c.
        pixels = (200 + 0.1 * (rows + 0.5) + 0.2 * (columns + 0.5)).astype("float32")
        pixels[12, 12] += 18  # one 10 m pixel beside post (first + 2, first + 2)
        pixels[150:] = -999999
        with self.fine_tile(pixels) as memory, memory.open() as dataset, rasterio.Env():
            posts = sample_elevation.tile_cell(dataset, (-74, 40))
            with self.assertRaisesRegex(ValueError, "middle of N41W074"):
                sample_elevation.tile_cell(dataset, (-74, 41))
        self.assertEqual(posts.shape, (build_elevation.POSTS,) * 2)
        post_rows, post_columns = np.mgrid[0:46, 0:96]
        plane = 200 + 0.1 * (6 + 3 * post_rows) + 0.2 * (6 + 3 * post_columns)
        spike = posts[first:first + 46, first:first + 96] - plane
        # The spike is spread over the posts around it and keeps its volume: a ninth of a post's area.
        self.assertTrue(1 < spike[2, 2] < 2, spike[2, 2])
        self.assertAlmostEqual(float(spike.sum()), 18 / 9, places=2)
        spike[1:5, 1:5] = 0
        np.testing.assert_allclose(spike, 0, atol=1e-3)
        # Pixels without data give posts without data; so does the rest of the cell.
        self.assertTrue(np.isnan(posts[first + 50:]).all() and np.isnan(posts[:, first + 100:]).all())
        self.assertTrue(np.isnan(posts[:first - 3]).all() and np.isnan(posts[:, :first - 3]).all())
        with self.fine_tile(pixels, crs="EPSG:32618") as memory, memory.open() as dataset:
            with self.assertRaisesRegex(ValueError, "geographic"):
                sample_elevation.tile_cell(dataset, (-74, 40))

    def test_missing_posts_are_filled_from_another_tile_set(self):
        import numpy as np

        heights = np.array([[1, np.nan], [np.nan, 4]], dtype="float32")
        fallback = np.array([[9, 8], [np.nan, 7]], dtype="float32")
        filled, count = sample_elevation.fill_missing(heights, fallback)
        self.assertEqual(count, 1)
        np.testing.assert_array_equal(filled, np.array([[1, 8], [np.nan, 4]], dtype="float32"))

    def test_tile_arguments_name_every_cell_once(self):
        cells = [(-75, 40), (-74, 40)]
        self.assertEqual(sample_elevation.cell_of("S35W059"), (-59, -35))
        self.assertEqual(sample_elevation.tile_sources(["N40W074=a.tif", "N40W075=https://host/b.tif?x=1"], cells),
                         {(-74, 40): "a.tif", (-75, 40): "https://host/b.tif?x=1"})
        for bad in (["N40W074=a.tif"], ["N40W074=a.tif", "N40W074=b.tif", "N40W075=c.tif"],
                    ["N40W074=a.tif", "N40W075=b.tif", "N41W074=c.tif"], ["N40W074", "N40W075=b.tif"],
                    ["N40W74=a.tif", "N40W075=b.tif"], ["S00W074=a.tif", "N40W075=b.tif"]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                sample_elevation.tile_sources(bad, cells)
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            sample_elevation.read_source("http://host/a.tif")

    def test_tiles_command_writes_a_filled_sample_and_its_sources(self):
        import numpy as np

        first = self.FIRST_POST
        pixels = np.full((300, 300), 12.4, dtype="float32")
        pixels[150:] = -999999
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.fine_tile(pixels) as memory:
                (root / "USGS_13_n41w074_20260917.tif").write_bytes(memory.read())
            fill = root / "opened"
            fallback = np.full((build_elevation.POSTS,) * 2, 30, dtype="float32")
            fallback[:, 3000:] = np.nan
            sample_elevation.write_manifest(
                fill, {"name": "grey-opening"}, [{"id": "copernicus-glo30"}],
                [sample_elevation.write_hgt(fill, (-74, 40), fallback)], [-74, 40, -73, 41])
            out = root / "hybrid"
            arguments = ["sample_elevation.py", "tiles", "--source-id", "usgs-3dep-13", "--bounds", "-74", "40",
                         "-73", "41", "--tile", f"N40W074={root / 'USGS_13_n41w074_20260917.tif'}",
                         "--fill", str(fill), "--out", str(out)]
            with patch("sys.argv", arguments), patch("builtins.print"):
                sample_elevation.main()
            posts = sample_elevation.read_hgt(build_elevation.hgt_path(out, -74, 40))
            self.assertEqual((float(posts[first + 10, first + 10]), float(posts[first + 60, first + 10]),
                              float(posts[0, 0])), (12, 30, 30))
            self.assertTrue(np.isnan(posts[:, 3000:]).all())
            manifest = json.loads((out / "elevation-manifest.json").read_text())
            self.assertEqual(manifest["method"]["fill"]["cellListSha256"],
                             json.loads((fill / "elevation-manifest.json").read_text())["cellListSha256"])
            tile, = manifest["sources"][0]["tiles"]
            self.assertEqual((tile["cell"], tile["file"]), ("N40W074", "USGS_13_n41w074_20260917.tif"))
            self.assertEqual(tile["sha256"],
                             hashlib.sha256((root / "USGS_13_n41w074_20260917.tif").read_bytes()).hexdigest())
            filled = manifest["cellFiles"][0]["filledPosts"]
            self.assertEqual(manifest["sources"][1], {"id": "fill-with-copernicus-glo30", "posts": filled, "cells": 1})
            self.assertEqual(filled + manifest["noDataPosts"] + int((posts == 12).sum()), build_elevation.POSTS ** 2)
            self.assertEqual(elevation_identity(out, sample=True)["sources"],
                             ["usgs-3dep-13", "fill-with-copernicus-glo30"])
            with patch("sys.argv", arguments[:-1] + [str(root / "again")] + ["--tile", "N41W074=x.tif"]), \
                    patch("sys.stderr"), self.assertRaises(SystemExit):
                sample_elevation.main()
            self.assertFalse((root / "again").exists())

    def test_sample_manifests_are_only_accepted_for_sample_builds(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            entry = {"cell": "N47E008", "hgtSha256": "ab", "fileBytes": 3, "noDataPosts": 0}
            sample_elevation.write_manifest(out, {"name": "cog"}, [{"id": "gedtm30-v1.2"}], [entry], [8, 47, 9, 48])
            self.assertEqual(elevation_identity(out, sample=True)["sources"], ["gedtm30-v1.2"])
            with self.assertRaisesRegex(ValueError, "part of the source"):
                elevation_identity(out)
        with self.assertRaises(ValueError):
            sample_elevation.cells_in([9, 47, 8, 48])


if __name__ == "__main__":
    unittest.main()
