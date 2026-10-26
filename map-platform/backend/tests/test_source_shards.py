from __future__ import annotations

import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from xml.etree import ElementTree

from map_platform.source_shards import NoShardCoverageError, prepare_shards, select_shards


@unittest.skipUnless(shutil.which("osmium"), "osmium CLI is required")
class SourceShardTests(unittest.TestCase):
    def test_regional_shards_match_full_source_extract_across_grid_edge(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_xml = root / "source.osm"
            source_xml.write_text(
                '<osm version="0.6">'
                '<node id="1" version="2" lon="0.9" lat="0.1"/>'
                '<node id="2" version="2" lon="1.0" lat="0.1"/>'
                '<node id="3" version="2" lon="1.1" lat="0.1"/>'
                '<node id="4" version="1" lon="0.99" lat="0.1">'
                '<tag k="amenity" v="toilets"/></node>'
                '<node id="5" version="1" lon="1.01" lat="0.1">'
                '<tag k="shop" v="bicycle"/></node>'
                '<node id="6" version="1" lon="0.98" lat="0.08"/>'
                '<node id="7" version="1" lon="1.02" lat="0.08"/>'
                '<node id="8" version="1" lon="1.02" lat="0.12"/>'
                '<node id="9" version="1" lon="0.98" lat="0.12"/>'
                '<way id="10" version="2"><nd ref="1"/><nd ref="2"/><nd ref="3"/>'
                '<tag k="building" v="yes"/></way>'
                '<way id="11" version="1"><nd ref="6"/><nd ref="7"/>'
                '<nd ref="8"/><nd ref="9"/><nd ref="6"/>'
                '<tag k="amenity" v="cafe"/></way>'
                '<relation id="20" version="2"><member type="way" ref="10" role="outline"/>'
                '<tag k="type" v="building"/></relation>'
                '<relation id="21" version="1"><member type="way" ref="11" role="outer"/>'
                '<tag k="type" v="multipolygon"/>'
                '<tag k="shop" v="supermarket"/></relation></osm>'
            )
            source_pbf = root / "source.osm.pbf"
            subprocess.run(["osmium", "sort", str(source_xml), "-o", str(source_pbf)], check=True)
            sha = hashlib.sha256(source_pbf.read_bytes()).hexdigest()
            cache = root / "cache"
            with patch("map_platform.source_shards.shutil.disk_usage",
                       return_value=SimpleNamespace(free=0)):
                with self.assertRaisesRegex(ValueError, "insufficient local space"):
                    prepare_shards(source_pbf, sha, cache, (0, 0, 2, 1))
            # This is a tiny fixture; isolate the production 16 GiB safety
            # reserve so the equivalence assertion runs on low-disk hosts.
            with patch("map_platform.source_shards.shutil.disk_usage",
                       return_value=SimpleNamespace(free=1 << 40)):
                manifest = prepare_shards(source_pbf, sha, cache, (0, 0, 2, 1))
                self.assertEqual(prepare_shards(source_pbf, sha, cache, (0, 0, 2, 1)), manifest)
                shards = select_shards(cache, sha, [(0.95, 0.05, 1.05, 0.15)])
            self.assertEqual(len(shards), 2)
            merged = root / "merged.osm.pbf"
            subprocess.run(["osmium", "merge", *(str(path) for path in shards),
                            "-o", str(merged)], check=True)
            direct = root / "direct.osm.pbf"
            from_shards = root / "from-shards.osm.pbf"
            for source, output in ((source_pbf, direct), (merged, from_shards)):
                subprocess.run(["osmium", "extract", "--strategy=smart",
                                "--option=types=multipolygon,building", "-b",
                                "0.95,0.05,1.05,0.15", str(source), "-o", str(output)], check=True)

            def objects(path):
                result = subprocess.run(["osmium", "cat", str(path), "-f", "osm"],
                                        check=True, capture_output=True, text=True)
                tree = ElementTree.fromstring(result.stdout)
                return [(obj.tag, obj.attrib.get("id"), obj.attrib.get("version"),
                         [(child.tag, tuple(sorted(child.attrib.items()))) for child in obj])
                        for obj in tree]

            direct_objects = objects(direct)
            self.assertEqual(objects(from_shards), direct_objects)
            included_ids = {(kind, object_id) for kind, object_id, *_ in direct_objects}
            self.assertTrue({("node", "4"), ("node", "5"), ("way", "11"),
                             ("relation", "21")} <= included_ids)
            tags = {
                (kind, object_id): {
                    dict(attributes)["k"]: dict(attributes)["v"]
                    for child, attributes in children if child == "tag"
                }
                for kind, object_id, _, children in direct_objects
            }
            self.assertEqual(tags[("node", "4")]["amenity"], "toilets")
            self.assertEqual(tags[("node", "5")]["shop"], "bicycle")
            self.assertEqual(tags[("way", "11")]["amenity"], "cafe")
            self.assertEqual(tags[("relation", "21")]["shop"], "supermarket")
            with patch("map_platform.source_shards.shutil.disk_usage",
                       return_value=SimpleNamespace(free=1 << 40)):
                with self.assertRaisesRegex(NoShardCoverageError, "no ready"):
                    select_shards(cache, sha, [(2.1, 0.1, 2.2, 0.2)])
            shards[0].write_bytes(b"corrupt")
            with patch("map_platform.source_shards.shutil.disk_usage",
                       return_value=SimpleNamespace(free=1 << 40)):
                with self.assertRaisesRegex(ValueError, "differs"):
                    select_shards(cache, sha, [(0.95, 0.05, 1.05, 0.15)])
