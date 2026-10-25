"""Real Osmium/OGR POI equivalence across sealed source shards and profiles.

The normal host suite may lack native tools. CI also runs this module in the
production tools image with OBC_REQUIRE_POI_OGR_TESTS=1, where skipping is an
error. No country data, network service, signing key or device is required.
"""

from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from xml.etree import ElementTree as ET

from shapely.geometry import Point, shape

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT.parents[1] / "map-platform" / "backend"))

from building_calibration_cache import canonical_json  # noqa: E402
from building_pipeline import load_rules  # noqa: E402
from building_source_index import BuildingSourceIndex  # noqa: E402
from map_format import encode_poi_section  # noqa: E402
from map_platform.source_shards import prepare_shards, select_shards  # noqa: E402
from poi_pipeline import load_poi_config, prepare_pois, records_by_block  # noqa: E402


class PoiSourceEquivalenceTests(unittest.TestCase):
    BOUNDS = (0.94, 0.04, 1.06, 0.16)
    EXPECTED = {"n1": 1, "n2": 2, "n3": 3, "n4": 4, "n5": 5,
                "w100": 2, "r200": 1, "r201": 5}

    @classmethod
    def _command(cls, args):
        environment = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
        environment["PATH"] = os.pathsep.join((str(Path(sys.executable).parent),
                                               environment.get("PATH", "")))
        result = subprocess.run([str(arg) for arg in args], env=environment,
                                text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(f"command failed: {args}\n{result.stdout}\n{result.stderr}")
        return result

    @classmethod
    def setUpClass(cls):
        missing = [name for name in ("osmium", "ogr2ogr") if not shutil.which(name)]
        if missing:
            reason = f"real POI equivalence requires {', '.join(missing)}"
            if os.environ.get("OBC_REQUIRE_POI_OGR_TESTS") == "1":
                raise RuntimeError(reason)
            raise unittest.SkipTest(reason)
        temporary = tempfile.TemporaryDirectory(prefix="poi-source-equivalence-")
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        source_xml = cls.root / "source.osm"
        cls._fixture(source_xml)
        cls.source = cls.root / "source.osm.pbf"
        cls._command(["osmium", "sort", source_xml, "-o", cls.source])
        cls.source_sha = hashlib.sha256(cls.source.read_bytes()).hexdigest()
        cls.config = load_poi_config(ROOT / "conf" / "poi_categories.yaml")
        # This fixture deliberately has no buildings. POIs must be retained
        # from the general source even with an empty specialized building index.
        index = BuildingSourceIndex(cls.root / "building-index", cls.source_sha)
        index.build(nodes=[], ways=[], relations=[])
        cls.index_manifest = index.manifest_path
        cls.scope = cls._scope()
        cls.inputs = {"full": cls.source}
        for state in ("cold", "warm"):
            # Retain the production reserve; only mock available fixture disk
            # space, as the existing source-shard test does for tiny inputs.
            with patch("map_platform.source_shards.shutil.disk_usage",
                       return_value=SimpleNamespace(free=1 << 40)):
                manifest = prepare_shards(cls.source, cls.source_sha,
                                          cls.root / "shards", (0, 0, 2, 1))
                selected = select_shards(cls.root / "shards", cls.source_sha,
                                         [cls.BOUNDS])
            if len(selected) != 2:
                raise AssertionError("fixture must select both one-degree source shards")
            if state == "cold":
                cls.sealed_manifest = manifest.read_bytes()
            elif manifest.read_bytes() != cls.sealed_manifest:
                raise AssertionError("warm preparation changed the sealed source identity")
            merged = cls.root / f"{state}-merged.osm.pbf"
            cls._command(["osmium", "merge", *selected, "-o", merged])
            clipped = cls.root / f"{state}-clipped.osm.pbf"
            cls._command(["osmium", "extract", "--strategy=smart",
                          "--option=types=multipolygon,building", "-b",
                          ",".join(map(str, cls.BOUNDS)), merged, "-o", clipped])
            cls.inputs[state] = clipped
        cls.converted = {}
        for source_kind, source in cls.inputs.items():
            for profile in ("default", "selected"):
                prefix = cls.root / f"{source_kind}-{profile}"
                args = ["bash", ROOT / "scripts" / "pbf_to_geojson.sh",
                        *map(str, cls.BOUNDS), source, prefix, "--renderer-format", "5"]
                if profile == "selected":
                    args.extend([cls.index_manifest, cls.scope, "0"])
                cls._command(args)
                layers = {layer: json.loads(Path(f"{prefix}_{layer}.geojson").read_text())["features"]
                          for layer in ("points", "polygons")}
                records, stats = prepare_pois(layers["points"], layers["polygons"], cls.config)
                sections = {block: encode_poi_section([record.encoded() for record in group])
                            for block, group in records_by_block(records).items()}
                cls.converted[(source_kind, profile)] = (records, stats, sections, layers)

    @classmethod
    def _fixture(cls, path):
        osm = ET.Element("osm", version="0.6", generator="open-bike-poi-fixture")
        ways = []
        relations = []

        def tags(element, values):
            for key, value in values.items():
                ET.SubElement(element, "tag", k=key, v=value)

        for identifier, lon, lat, values in (
            (1, .985, .065, {"shop": "bakery"}),
            (2, 1.015, .075, {"amenity": "fast_food"}),
            (3, .995, .095, {"amenity": "toilets"}),
            (4, 1.005, .135, {"amenity": "fuel"}),
            (5, 1.02, .145, {"amenity": "bicycle_repair_station"}),
            (6, .98, .14, {"shop": "vacant"}),
            (7, 1.2, .2, {"shop": "books"}),  # outside requested coverage
        ):
            node = ET.SubElement(osm, "node", id=str(identifier), version="1",
                                 lon=str(lon), lat=str(lat))
            tags(node, values)

        def ring(identifier, coordinates, values=None):
            refs = []
            for offset, (lon, lat) in enumerate(coordinates):
                node_id = identifier * 100 + offset
                ET.SubElement(osm, "node", id=str(node_id), version="1",
                              lon=str(lon), lat=str(lat))
                refs.append(node_id)
            way = ET.Element("way", id=str(identifier), version="1")
            for ref in [*refs, refs[0]]:
                ET.SubElement(way, "nd", ref=str(ref))
            tags(way, values or {})
            ways.append(way)

        ring(100, [(.97, .08), (1.03, .08), (1.03, .11), (1.01, .11),
                   (1.01, .095), (.99, .095), (.99, .11), (.97, .11)],
             {"amenity": "cafe"})
        ring(110, [(.96, .115), (1.04, .115), (1.04, .155), (.96, .155)])
        ring(111, [(.98, .125), (1.02, .125), (1.02, .145), (.98, .145)])
        ring(120, [(.975, .045), (1.025, .045), (1.025, .075), (.975, .075)])
        ring(121, [(1.035, .045), (1.045, .045), (1.045, .055), (1.035, .055)])
        for identifier, members, values in (
            (200, [(110, "outer"), (111, "inner")], {"shop": "supermarket"}),
            (201, [(120, "outer"), (121, "outer")], {"shop": "bicycle"}),
        ):
            relation = ET.Element("relation", id=str(identifier), version="1")
            for way, role in members:
                ET.SubElement(relation, "member", type="way", ref=str(way), role=role)
            tags(relation, {"type": "multipolygon", **values})
            relations.append(relation)
        osm.extend(ways)
        osm.extend(relations)
        ET.ElementTree(osm).write(path, encoding="utf-8", xml_declaration=True)

    @classmethod
    def _scope(cls):
        rules, _ = load_rules(ROOT / "conf" / "building_height_rules.yaml")
        radius = 6_378_137
        west, south, east, north = cls.BOUNDS
        min_x, max_x = [math.radians(lon) * radius for lon in (west, east)]
        min_y, max_y = [math.log(math.tan(math.radians(lat) / 2 + math.pi / 4)) * radius
                        for lat in (south, north)]
        blocks = [{"x": x, "y": y, "boundsMeters": [x * 4096, y * 4096,
                                                            (x + 1) * 4096, (y + 1) * 4096]}
                  for x in range(math.floor(min_x / 4096), math.ceil(max_x / 4096))
                  for y in range(math.floor(min_y / 4096), math.ceil(max_y / 4096))]
        scope = {"schemaVersion": 1, "policy": {
            "policyVersion": 5, "blockGridVersion": 1, "blockSizeMeters": 4096,
            "selectionSemantics": "complete_blocks_no_selection_edge_clipping",
            "relationClosureMode": "source_snapshot_index", "maxRelationObjectsPerJob": 1000,
            "geometryBufferMeters": 256, "relationRetryBufferMeters": 512,
            "maxGeometryBufferMeters": 2048,
        }, "outputBlocks": blocks, "calibration": {
            "cellSizeMeters": rules.cell_size_meters, "haloCells": rules.halo_cells,
            "minimumSamples": rules.minimum_samples, "sampleCells": [],
        }}
        scope["scopePlanSha256"] = hashlib.sha256(canonical_json(scope)).hexdigest()
        path = cls.root / "scope-plan.json"
        path.write_bytes(canonical_json(scope) + b"\n")
        return path

    def test_full_and_cold_warm_prepared_sources_have_identical_records_and_sections(self):
        baseline_records, baseline_stats, baseline_sections, _ = self.converted[("full", "default")]
        self.assertEqual({record.object_key: record.category for record in baseline_records}, self.EXPECTED)
        self.assertEqual(len(baseline_records), len(self.EXPECTED))
        self.assertGreater(len(baseline_sections), 1)
        for path, (records, stats, sections, _) in self.converted.items():
            with self.subTest(path=path):
                self.assertEqual(records, baseline_records)
                self.assertEqual(sections, baseline_sections)
                for key in ("recordCount", "shopsCount", "restaurantsAndCafesCount",
                            "publicToiletsCount", "gasStationsCount", "bicycleServicesCount",
                            "pointRecordCount", "areaRecordCount", "blocksWithPois"):
                    self.assertEqual(stats[key], baseline_stats[key], key)
                self.assertEqual(Counter(record.object_key for record in records),
                                 Counter(self.EXPECTED.keys()))

    def test_area_anchors_preserve_holes_concavity_and_single_multipolygon_identity(self):
        records, _, _, layers = self.converted[("full", "selected")]
        areas = {}
        for item in layers["polygons"]:
            properties = item["properties"]
            key = ("w" + str(properties["osm_way_id"]) if properties.get("osm_way_id")
                   else "r" + str(properties.get("osm_id")))
            areas[key] = shape(item["geometry"])
        holed = areas["r200"]
        polygons = holed.geoms if holed.geom_type == "MultiPolygon" else (holed,)
        self.assertEqual(sum(len(polygon.interiors) for polygon in polygons), 1)
        self.assertFalse(areas["w100"].equals(areas["w100"].convex_hull))
        self.assertEqual(len(areas["r201"].geoms), 2)
        for record in records:
            if record.source_kind != "area":
                continue
            geometry = areas[record.object_key]
            self.assertNotEqual(math.floor(geometry.bounds[0] / 4096),
                                math.floor(geometry.bounds[2] / 4096))
            anchor = Point(record.block_x + record.local_x,
                           record.block_y + record.local_y)
            self.assertTrue(geometry.contains(anchor), record.object_key)
            if record.object_key == "r201":
                self.assertTrue(max(geometry.geoms, key=lambda polygon: polygon.area).contains(anchor))


if __name__ == "__main__":
    unittest.main()
