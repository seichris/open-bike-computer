from __future__ import annotations

import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from xml.etree import ElementTree

from map_platform.source_shards import prepare_shards, select_shards


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
                '<way id="10" version="2"><nd ref="1"/><nd ref="2"/><nd ref="3"/>'
                '<tag k="building" v="yes"/></way>'
                '<relation id="20" version="2"><member type="way" ref="10" role="outline"/>'
                '<tag k="type" v="building"/></relation></osm>'
            )
            source_pbf = root / "source.osm.pbf"
            subprocess.run(["osmium", "sort", str(source_xml), "-o", str(source_pbf)], check=True)
            sha = hashlib.sha256(source_pbf.read_bytes()).hexdigest()
            cache = root / "cache"
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

            self.assertEqual(objects(from_shards), objects(direct))
            with self.assertRaisesRegex(ValueError, "no ready"):
                select_shards(cache, sha, [(2.1, 0.1, 2.2, 0.2)])
            shards[0].write_bytes(b"corrupt")
            with self.assertRaisesRegex(ValueError, "differs"):
                select_shards(cache, sha, [(0.95, 0.05, 1.05, 0.15)])
