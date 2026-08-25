import json
import hashlib
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from building_calibration_cache import canonical_json  # noqa: E402
from building_source_index import BuildingSourceIndex  # noqa: E402
from build_building_source_index import scan_source  # noqa: E402
from extract_building_relations import (  # noqa: E402
    BuildingRelationHandler,
    _closure_rows,
    load_source_index_manifest,
)


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "building_relations.osm"
SINGAPORE_FIXTURE = (
    Path(__file__).resolve().parent / "fixtures" / "singapore_r14346906.osm"
)
SCRIPT = ROOT / "scripts" / "extract_building_relations.py"


class BuildingRelationIngressTests(unittest.TestCase):
    def test_closure_rows_batches_source_audit_queries(self):
        connection = sqlite3.connect(":memory:")
        try:
            connection.execute("CREATE TABLE ways (object_key TEXT, nodes_json TEXT)")
            connection.executemany(
                "INSERT INTO ways VALUES (?, ?)",
                ((f"w{index}", "[]") for index in range(5)),
            )
            statements = []
            connection.set_trace_callback(statements.append)
            rows = dict(
                _closure_rows(
                    connection,
                    table="ways",
                    value_column="nodes_json",
                    keys={f"w{index}" for index in range(5)},
                    batch_size=2,
                )
            )
            self.assertEqual(set(rows), {f"w{index}" for index in range(5)})
            self.assertEqual(
                len([statement for statement in statements if statement.startswith("SELECT")]),
                3,
            )
        finally:
            connection.close()

    def test_source_index_manifest_loader_skips_full_database_rescan(self):
        sentinel = object()
        with patch(
            "extract_building_relations.BuildingSourceIndex.from_manifest",
            return_value=sentinel,
        ) as from_manifest:
            self.assertIs(load_source_index_manifest("sealed-manifest.json"), sentinel)
        from_manifest.assert_called_once_with(
            "sealed-manifest.json",
            validate_database=False,
        )

    @staticmethod
    def relation(relation_id, members, tags=None):
        class Tags(list):
            def get(self, key):
                return next((tag.v for tag in self if tag.k == key), None)

        return SimpleNamespace(
            id=relation_id,
            tags=Tags(
                SimpleNamespace(k=key, v=value)
                for key, value in (tags or {"type": "building"}).items()
            ),
            members=[SimpleNamespace(**member) for member in members],
        )

    def test_single_outer_and_building_part_roles_are_safe_aliases(self):
        handler = BuildingRelationHandler(
            expected_closure={"requiredRelationKeys": ["r104"]}
        )
        handler.relation(
            self.relation(
                104,
                [
                    {"type": "w", "ref": 12, "role": "outer"},
                    {"type": "w", "ref": 21, "role": "part"},
                    {"type": "w", "ref": 22, "role": "building:part"},
                ],
            )
        )
        self.assertEqual(handler.part_parents, {"w21": "w12", "w22": "w12"})
        self.assertFalse(handler.parts_without_outline)

    def test_multiple_outer_aliases_remain_without_an_explicit_parent(self):
        handler = BuildingRelationHandler(
            expected_closure={"requiredRelationKeys": ["r105"]}
        )
        handler.relation(
            self.relation(
                105,
                [
                    {"type": "w", "ref": 12, "role": "outer"},
                    {"type": "w", "ref": 13, "role": "outer"},
                    {"type": "w", "ref": 21, "role": "part"},
                ],
            )
        )
        self.assertFalse(handler.part_parents)
        self.assertEqual(handler.parts_without_outline, {"w21"})

    def test_multiple_explicit_outlines_defer_to_declared_containment(self):
        handler = BuildingRelationHandler(
            expected_closure={"requiredRelationKeys": ["r105"]}
        )
        handler.relation(
            self.relation(
                105,
                [
                    {"type": "w", "ref": 12, "role": "outline"},
                    {"type": "w", "ref": 13, "role": "outline"},
                    {"type": "w", "ref": 21, "role": "part"},
                ],
            )
        )
        handler.finalize()

        self.assertFalse(handler.part_parents)
        self.assertEqual(
            handler.deferred_part_parent_candidates,
            {"w21": ("w12", "w13")},
        )
        self.assertEqual(set(handler.parent_tags), {"w12", "w13"})
        self.assertEqual(handler.ambiguous_parts, 0)

    def test_part_shared_across_relations_remains_ambiguous(self):
        handler = BuildingRelationHandler(
            expected_closure={"requiredRelationKeys": ["r105", "r106"]}
        )
        for relation_id, outline_id in ((105, 12), (106, 13)):
            handler.relation(
                self.relation(
                    relation_id,
                    [
                        {"type": "w", "ref": outline_id, "role": "outline"},
                        {"type": "w", "ref": 21, "role": "part"},
                    ],
                )
            )
        handler.finalize()

        self.assertFalse(handler.part_parents)
        self.assertFalse(handler.deferred_part_parent_candidates)
        self.assertEqual(handler.ambiguous_parts, 1)

    def test_single_outer_multipolygon_can_restore_suppressed_outline_geometry(self):
        handler = BuildingRelationHandler(
            expected_closure={"requiredRelationKeys": ["r190", "r200"]}
        )
        handler.way_tags["w10"] = {
            "building": "office",
            "height": "40",
        }
        handler.relation(
            self.relation(
                190,
                [{"type": "w", "ref": 10, "role": "outer"}],
                tags={"type": "multipolygon", "building:part": "yes"},
            )
        )
        handler.relation(
            self.relation(
                200,
                [
                    {"type": "w", "ref": 10, "role": "outline"},
                    {"type": "r", "ref": 190, "role": "part"},
                ],
            )
        )
        handler.finalize()

        self.assertEqual(handler.parent_geometry_sources, {"w10": "r190"})
        self.assertEqual(
            handler.parent_tags["w10"],
            {"building": "office", "height": "40", "type": "building"},
        )
        self.assertEqual(handler.part_parents, {"r190": "w10"})
        self.assertEqual(handler.ambiguous_parts, 0)

    def test_part_only_relation_keeps_actionable_relation_identity(self):
        handler = BuildingRelationHandler(
            expected_closure={"requiredRelationKeys": ["r106"]}
        )
        handler.relation(
            self.relation(
                106,
                [{"type": "w", "ref": 30, "role": "part"}],
            )
        )
        self.assertEqual(handler.parts_without_outline, {"w30"})
        self.assertEqual(handler.incomplete_relation_parts, {"r106": ("w30",)})

    def test_single_explicit_building_part_is_retained_standalone(self):
        handler = BuildingRelationHandler(
            expected_closure={
                "requiredRelationKeys": ["r107"],
                "requiredWayKeys": ["w30"],
            }
        )

        class Tags(list):
            def get(self, key):
                return next((tag.v for tag in self if tag.k == key), None)

        handler.way(
            SimpleNamespace(
                id=30,
                nodes=[],
                tags=Tags([SimpleNamespace(k="building", v="yes")]),
            )
        )
        handler.relation(
            self.relation(
                107,
                [{"type": "w", "ref": 30, "role": "part"}],
            )
        )
        handler.finalize()

        self.assertEqual(handler.standalone_part_keys, {"w30"})
        self.assertFalse(handler.parts_without_outline)

    def test_unoutlined_building_relation_with_explicit_parts_is_retained_standalone(self):
        handler = BuildingRelationHandler(
            expected_closure={
                "requiredRelationKeys": ["r108"],
                "requiredWayKeys": ["w31", "w32"],
            }
        )

        class Tags(list):
            def get(self, key):
                return next((tag.v for tag in self if tag.k == key), None)

        for way_id in (31, 32):
            handler.way(
                SimpleNamespace(
                    id=way_id,
                    nodes=[],
                    tags=Tags([SimpleNamespace(k="building:part", v="yes")]),
                )
            )
        handler.relation(
            self.relation(
                108,
                [
                    {"type": "w", "ref": 31, "role": "part"},
                    {"type": "w", "ref": 32, "role": "part"},
                ],
            )
        )
        handler.finalize()

        self.assertEqual(handler.standalone_part_keys, {"w31", "w32"})
        self.assertFalse(handler.parts_without_outline)

    def test_unoutlined_relation_with_shared_part_remains_fail_closed(self):
        handler = BuildingRelationHandler(
            expected_closure={
                "requiredRelationKeys": ["r109", "r110"],
                "requiredWayKeys": ["w33"],
            }
        )

        class Tags(list):
            def get(self, key):
                return next((tag.v for tag in self if tag.k == key), None)

        handler.way(
            SimpleNamespace(
                id=33,
                nodes=[],
                tags=Tags([SimpleNamespace(k="building:part", v="yes")]),
            )
        )
        for relation_id in (109, 110):
            handler.relation(
                self.relation(
                    relation_id,
                    [{"type": "w", "ref": 33, "role": "part"}],
                )
            )
        handler.finalize()

        self.assertFalse(handler.standalone_part_keys)
        self.assertEqual(handler.parts_without_outline, {"w33"})

    def test_unoutlined_part_reused_as_outline_remains_fail_closed(self):
        handler = BuildingRelationHandler(
            expected_closure={
                "requiredRelationKeys": ["r111", "r112"],
                "requiredWayKeys": ["w33", "w34"],
            }
        )

        class Tags(list):
            def get(self, key):
                return next((tag.v for tag in self if tag.k == key), None)

        for way_id in (33, 34):
            handler.way(
                SimpleNamespace(
                    id=way_id,
                    nodes=[],
                    tags=Tags([SimpleNamespace(k="building:part", v="yes")]),
                )
            )
        handler.relation(
            self.relation(
                111,
                [
                    {"type": "w", "ref": 33, "role": "outline"},
                    {"type": "w", "ref": 34, "role": "part"},
                ],
            )
        )
        handler.relation(
            self.relation(
                112,
                [{"type": "w", "ref": 33, "role": "part"}],
            )
        )
        handler.finalize()

        self.assertFalse(handler.standalone_part_keys)
        self.assertEqual(handler.parts_without_outline, {"w33"})

    def test_singapore_r14346906_fixture_passes_exact_scope_closure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_sha = hashlib.sha256(SINGAPORE_FIXTURE.read_bytes()).hexdigest()
            index = BuildingSourceIndex(root / "cache", source_sha)
            index.build_with_scanner(
                lambda path: scan_source(SINGAPORE_FIXTURE, path)
            )
            scope = {
                "schemaVersion": 1,
                "policy": {
                    "relationClosureMode": "source_snapshot_index",
                    "maxRelationObjectsPerJob": 1_000,
                },
                # plan_building_scope for bbox [103.852, 1.302, 103.858, 1.308].
                "outputBlocks": [
                    {
                        "x": 2822,
                        "y": 35,
                        "boundsMeters": [11558912, 143360, 11563008, 147456],
                    }
                ],
                "calibration": {"cellSizeMeters": 8192, "haloCells": 1},
            }
            scope_path = root / "scope.json"
            scope_path.write_bytes(
                canonical_json(
                    {
                        **scope,
                        "scopePlanSha256": hashlib.sha256(
                            canonical_json(scope)
                        ).hexdigest(),
                    }
                )
            )
            output = root / "relation-index.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(SINGAPORE_FIXTURE),
                    str(output),
                    "--source-index-manifest",
                    str(index.manifest_path),
                    "--scope-plan",
                    str(scope_path),
                ],
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            value = json.loads(output.read_text())
            self.assertEqual(
                value["standalonePartKeys"],
                [
                    "w1077928781",
                    "w1077928782",
                    "w1077928783",
                    "w1077928784",
                    "w1077928785",
                ],
            )
            self.assertEqual(value["closureAudit"]["closureRelationCount"], 1)
            self.assertEqual(value["closureAudit"]["closureWayCount"], 5)
            self.assertEqual(value["closureAudit"]["closureNodeCount"], 20)
            self.assertEqual(value["closureAudit"]["relationRetryCount"], 0)

    def test_multi_outline_relation_passes_with_declared_parent_candidates(self):
        source_document = """<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6" generator="open-bike-computer-tests">
  <node id="1" lat="1.3030" lon="103.8530" version="1" />
  <node id="2" lat="1.3030" lon="103.8540" version="1" />
  <node id="3" lat="1.3040" lon="103.8540" version="1" />
  <node id="4" lat="1.3040" lon="103.8530" version="1" />
  <node id="5" lat="1.3030" lon="103.8550" version="1" />
  <node id="6" lat="1.3030" lon="103.8560" version="1" />
  <node id="7" lat="1.3040" lon="103.8560" version="1" />
  <node id="8" lat="1.3040" lon="103.8550" version="1" />
  <node id="9" lat="1.3032" lon="103.8552" version="1" />
  <node id="10" lat="1.3032" lon="103.8558" version="1" />
  <node id="11" lat="1.3038" lon="103.8558" version="1" />
  <node id="12" lat="1.3038" lon="103.8552" version="1" />
  <way id="10" version="1">
    <nd ref="1"/><nd ref="2"/><nd ref="3"/><nd ref="4"/><nd ref="1"/>
    <tag k="building" v="retail"/>
  </way>
  <way id="20" version="1">
    <nd ref="5"/><nd ref="6"/><nd ref="7"/><nd ref="8"/><nd ref="5"/>
    <tag k="building" v="office"/>
  </way>
  <way id="30" version="1">
    <nd ref="9"/><nd ref="10"/><nd ref="11"/><nd ref="12"/><nd ref="9"/>
    <tag k="building:part" v="yes"/>
  </way>
  <relation id="200" version="1">
    <member type="way" ref="10" role="outline"/>
    <member type="way" ref="20" role="outline"/>
    <member type="way" ref="30" role="part"/>
    <tag k="name" v="Two-building complex"/>
    <tag k="type" v="building"/>
  </relation>
</osm>
"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "multi-outline.osm"
            source.write_text(source_document)
            source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
            index = BuildingSourceIndex(root / "cache", source_sha)
            index.build_with_scanner(lambda path: scan_source(source, path))
            scope = {
                "schemaVersion": 1,
                "policy": {
                    "relationClosureMode": "source_snapshot_index",
                    "maxRelationObjectsPerJob": 1_000,
                },
                "outputBlocks": [
                    {
                        "x": 2822,
                        "y": 35,
                        "boundsMeters": [11558912, 143360, 11563008, 147456],
                    }
                ],
                "calibration": {"cellSizeMeters": 8192, "haloCells": 1},
            }
            scope_path = root / "scope.json"
            scope_path.write_bytes(
                canonical_json(
                    {
                        **scope,
                        "scopePlanSha256": hashlib.sha256(
                            canonical_json(scope)
                        ).hexdigest(),
                    }
                )
            )
            output = root / "relation-index.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(source),
                    str(output),
                    "--source-index-manifest",
                    str(index.manifest_path),
                    "--scope-plan",
                    str(scope_path),
                ],
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            value = json.loads(output.read_text())
            self.assertEqual(value["partParents"], {})
            self.assertEqual(
                value["partParentCandidates"],
                {"w30": ["w10", "w20"]},
            )
            self.assertEqual(set(value["parentTags"]), {"w10", "w20"})
            self.assertEqual(value["ambiguousParts"], 0)

    def test_cli_indexes_real_osm_building_relations_deterministically(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "building-relations.json"
            subprocess.run(
                [sys.executable, str(SCRIPT), str(FIXTURE), str(output)],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")),
                {
                    "schemaVersion": 1,
                    "partParents": {
                        "w20": "w10",
                        "w21": "w12",
                        "w22": "w12",
                    },
                    "parentTags": {
                        "w10": {"type": "building"},
                        "w11": {"type": "building"},
                        "w12": {"type": "building"},
                    },
                    "relations": 3,
                    "ambiguousParts": 1,
                },
            )
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                '{"ambiguousParts":1,"parentTags":{"w10":{"type":"building"},'
                '"w11":{"type":"building"},"w12":{"type":"building"}},'
                '"partParents":{"w20":"w10","w21":"w12","w22":"w12"},'
                '"relations":3,"schemaVersion":1}\n',
            )

    def test_source_index_audit_accepts_complete_closure_and_rejects_missing_way(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            clean_source = root / "clean.osm"
            clean_source.write_text(
                re.sub(
                    r'\s*<relation id="101".*?</relation>',
                    "",
                    FIXTURE.read_text(),
                    flags=re.DOTALL,
                )
            )
            source_sha = hashlib.sha256(clean_source.read_bytes()).hexdigest()
            index = BuildingSourceIndex(root / "cache", source_sha)
            index.build_with_scanner(lambda path: scan_source(clean_source, path))
            scope = {
                "schemaVersion": 1,
                "policy": {
                    "relationClosureMode": "source_snapshot_index",
                    "maxRelationObjectsPerJob": 100,
                },
                "outputBlocks": [
                    {
                        "x": 2821,
                        "y": 35,
                        "boundsMeters": [11554816, 143360, 11558912, 147456],
                    }
                ],
                "calibration": {
                    "cellSizeMeters": 8192,
                    "haloCells": 1,
                },
            }
            scope_path = root / "scope.json"
            scope_path.write_bytes(
                canonical_json(
                    {
                        **scope,
                        "scopePlanSha256": hashlib.sha256(
                            canonical_json(scope)
                        ).hexdigest(),
                    }
                )
            )
            output = root / "complete.json"
            complete = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(clean_source),
                    str(output),
                    "--source-index-manifest", str(index.manifest_path),
                    "--scope-plan", str(scope_path),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(complete.returncode, 0, complete.stdout + complete.stderr)
            audit = json.loads(output.read_text())["closureAudit"]
            self.assertEqual(audit["relationRetryCount"], 0)
            self.assertEqual(audit["closureRelationCount"], 4)
            self.assertEqual(audit["sourceSnapshotSha256"], source_sha)

            safe_source = root / "safe-standalone.osm"
            safe_source.write_text(
                clean_source.read_text().replace(
                    "</osm>",
                    '<relation id="108" version="1">'
                    '<member type="way" ref="10" role="part" />'
                    '<tag k="type" v="building" />'
                    "</relation></osm>",
                )
            )
            safe_sha = hashlib.sha256(safe_source.read_bytes()).hexdigest()
            safe_index = BuildingSourceIndex(root / "safe-cache", safe_sha)
            safe_index.build_with_scanner(lambda path: scan_source(safe_source, path))
            safe_output = root / "safe.json"
            safe = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(safe_source),
                    str(safe_output),
                    "--source-index-manifest", str(safe_index.manifest_path),
                    "--scope-plan", str(scope_path),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(safe.returncode, 0, safe.stdout + safe.stderr)
            self.assertEqual(
                json.loads(safe_output.read_text())["standalonePartKeys"],
                ["w10"],
            )

            malformed_source = root / "malformed.osm"
            malformed_source.write_text(
                clean_source.read_text().replace(
                    "</osm>",
                    '<relation id="106" version="1">'
                    '<member type="way" ref="20" role="part" />'
                    '<tag k="type" v="building" />'
                    "</relation></osm>",
                )
            )
            malformed_sha = hashlib.sha256(malformed_source.read_bytes()).hexdigest()
            malformed_index = BuildingSourceIndex(root / "malformed-cache", malformed_sha)
            malformed_index.build_with_scanner(
                lambda path: scan_source(malformed_source, path)
            )
            malformed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(malformed_source),
                    str(root / "malformed.json"),
                    "--source-index-manifest", str(malformed_index.manifest_path),
                    "--scope-plan", str(scope_path),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(malformed.returncode, 2, malformed.stdout + malformed.stderr)
            self.assertIn("source relation r106 has part members but no outline", malformed.stdout)
            self.assertIn(
                "w20[r=1,b=-,bp=1;s=1,b=-,bp=1;inc=1,parents=1,outline=0]",
                malformed.stdout,
            )

            runtime_untagged_source = root / "runtime-untagged.osm"
            runtime_untagged_source.write_text(
                re.sub(
                    r'(<way id="20".*?)(\s*<tag k="building:part" v="yes" />)',
                    r"\1",
                    malformed_source.read_text(),
                    count=1,
                    flags=re.DOTALL,
                )
            )
            runtime_untagged = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(runtime_untagged_source),
                    str(root / "runtime-untagged.json"),
                    "--source-index-manifest", str(malformed_index.manifest_path),
                    "--scope-plan", str(scope_path),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(
                runtime_untagged.returncode,
                2,
                runtime_untagged.stdout + runtime_untagged.stderr,
            )
            self.assertIn(
                "w20[r=1,b=-,bp=-;s=1,b=-,bp=1;inc=1,parents=1,outline=0]",
                runtime_untagged.stdout,
            )

            incomplete_fixture = root / "incomplete.osm"
            incomplete_fixture.write_text(
                re.sub(
                    r'\s*<way id="20".*?</way>',
                    "",
                    clean_source.read_text(),
                    flags=re.DOTALL,
                )
            )
            failed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(incomplete_fixture),
                    str(root / "incomplete.json"),
                    "--source-index-manifest", str(index.manifest_path),
                    "--scope-plan", str(scope_path),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(failed.returncode, 2, failed.stdout + failed.stderr)
            marker = next(
                line.split(":", 1)[1]
                for line in failed.stdout.splitlines()
                if line.startswith("BUILDING_PREPROCESS_FAILURE:")
            )
            self.assertEqual(json.loads(marker)["code"], "building_relation_incomplete")

            empty = root / "empty.osm"
            empty.write_text('<?xml version="1.0"?><osm version="0.6"></osm>')
            omitted = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(empty),
                    str(root / "omitted.json"),
                    "--source-index-manifest", str(index.manifest_path),
                    "--scope-plan", str(scope_path),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(omitted.returncode, 2, omitted.stdout + omitted.stderr)
            self.assertIn("building_relation_incomplete", omitted.stdout)


if __name__ == "__main__":
    unittest.main()
