import json
import hashlib
import math
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from building_calibration_cache import (  # noqa: E402
    CalibrationCache,
    CalibrationIdentity,
    canonical_json,
)
from building_pipeline import load_rules  # noqa: E402


ROOT = pathlib.Path(__file__).resolve().parents[1]
EARTH_RADIUS_METERS = 6_378_137
HOST_FONT_CANDIDATES = (
    pathlib.Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
    pathlib.Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
)


def write_block_cache_identity(
    root, source_sha, rules_sha, calibration_key, calibration_manifest
):
    manifest = json.loads(calibration_manifest.read_bytes())
    body = {
        "schemaVersion": 1,
        "sourceSnapshotSha256": source_sha,
        "rulesSha256": rules_sha,
        "buildingProfileVersion": 1,
        "rendererFormatVersion": 3,
        "fmbVersion": 4,
        "blockGridVersion": 1,
        "blockSizeMeters": 4096,
        "selectionSemantics": "complete_blocks_no_selection_edge_clipping",
        "geometryBufferMeters": 256,
        "relationRetryBufferMeters": 512,
        "maxGeometryBufferMeters": 2048,
        "normalizationAlgorithmVersion": 2,
        "blockEncodingAlgorithmVersion": 1,
        "geometryEngine": {"name": "shapely", "version": "2.0.7"},
        "sourceIndex": {"schemaVersion": 1, "algorithmVersion": 2},
        "closureAlgorithmVersion": 1,
        "calibration": {
            "algorithmVersion": 1,
            "calibrationKey": calibration_key,
            "manifestSha256": manifest["manifestSha256"],
            "entrySetSha256": hashlib.sha256(
                canonical_json(manifest["cells"])
            ).hexdigest(),
        },
    }
    value = {
        **body,
        "cacheIdentitySha256": hashlib.sha256(canonical_json(body)).hexdigest(),
    }
    path = root / "building-block-cache-identity.json"
    path.write_bytes(canonical_json(value) + b"\n")
    return path


class Target3CLITests(unittest.TestCase):
    def test_target_three_preflight_failures_use_typed_protocol(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            invalid_scope = root / "invalid-scope.json"
            invalid_scope.write_text("not-json", encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "extract_features.py"),
                    "0",
                    "0",
                    "0.01",
                    "0.01",
                    str(root / "features"),
                    str(root / "map"),
                    "--renderer-format",
                    "3",
                    "--scope-plan",
                    str(invalid_scope),
                ],
                cwd=ROOT / "scripts",
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            marker = next(
                line.split(":", 1)[1]
                for line in result.stdout.splitlines()
                if line.startswith("BUILDING_PREPROCESS_FAILURE:")
            )
            self.assertEqual(
                json.loads(marker),
                {
                    "code": "building_scope_policy_invalid",
                    "message": "scope plan is unavailable or invalid",
                },
            )

    def test_ogr_untagged_relation_outline_reaches_strict_target_three(self):
        host_font = next(
            (path for path in HOST_FONT_CANDIDATES if path.is_file()),
            None,
        )
        self.assertIsNotNone(host_font, "host font fixture is unavailable")
        if shutil.which("ogr2ogr") is None:
            self.skipTest("GDAL ogr2ogr is unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            prefix = root / "features"
            source = (
                ROOT
                / "tests"
                / "fixtures"
                / "untagged_building_relation.osm"
            )
            environment = os.environ.copy()
            environment["PATH"] = os.pathsep.join(
                (str(pathlib.Path(sys.executable).parent), environment.get("PATH", ""))
            )
            environment.update(
                {
                    "OBC_LABEL_LATIN_FONT": str(host_font),
                    "OBC_LABEL_CJK_FONT": str(host_font),
                }
            )
            rules, rules_sha = load_rules(
                ROOT / "conf" / "building_height_rules.yaml"
            )
            source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
            sample_cells = [
                (x, y) for x in range(-1, 2) for y in range(-1, 2)
            ]
            scope = {
                "schemaVersion": 1,
                "policy": {
                    "policyVersion": 5,
                    "blockGridVersion": 1,
                    "blockSizeMeters": 4096,
                    "selectionSemantics": "complete_blocks_no_selection_edge_clipping",
                    "relationClosureMode": "source_snapshot_index",
                    "maxRelationObjectsPerJob": 1_000,
                    "geometryBufferMeters": 256,
                    "relationRetryBufferMeters": 512,
                    "maxGeometryBufferMeters": 2048,
                },
                "outputBlocks": [
                    {"x": 0, "y": 0, "boundsMeters": [0, 0, 4096, 4096]}
                ],
                "calibration": {
                    "cellSizeMeters": rules.cell_size_meters,
                    "haloCells": rules.halo_cells,
                    "minimumSamples": rules.minimum_samples,
                    "sampleCells": [list(cell) for cell in sample_cells],
                },
            }
            scope_sha = hashlib.sha256(canonical_json(scope)).hexdigest()
            scope_path = root / "scope-plan.json"
            scope_path.write_bytes(
                canonical_json({**scope, "scopePlanSha256": scope_sha}) + b"\n"
            )
            source_index_result = root / "source-index-result.json"
            indexed = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "build_building_source_index.py"),
                    "--source-pbf",
                    str(source),
                    "--source-sha256",
                    source_sha,
                    "--cache-root",
                    str(root / "cache"),
                    "--result-json",
                    str(source_index_result),
                ],
                cwd=ROOT / "scripts",
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(indexed.returncode, 0, indexed.stdout + indexed.stderr)
            source_index_manifest = json.loads(
                source_index_result.read_text()
            )["manifestPath"]
            converted = subprocess.run(
                [
                    "bash",
                    str(ROOT / "scripts" / "pbf_to_geojson.sh"),
                    "0",
                    "0",
                    "0.02",
                    "0.02",
                    str(source),
                    str(prefix),
                    source_index_manifest,
                    str(scope_path),
                    "0",
                ],
                cwd=ROOT / "scripts",
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(
                converted.returncode,
                0,
                converted.stdout + converted.stderr,
            )
            lines = json.loads((root / "features_lines.geojson").read_text())
            self.assertIn(
                "10",
                {str(item["properties"].get("osm_id")) for item in lines["features"]},
            )
            relation_path = root / "features_building_relations.json"
            relation_index = json.loads(relation_path.read_text())
            self.assertEqual(relation_index["partParents"], {"w20": "w10"})
            self.assertEqual(
                relation_index["parentTags"]["w10"]["height"],
                "20",
            )
            self.assertEqual(
                relation_index["closureAudit"]["closureWayCount"],
                2,
            )
            self.assertEqual(
                relation_index["closureAudit"]["closureNodeCount"],
                8,
            )

            calibration_cache = CalibrationCache(
                root / "cache",
                CalibrationIdentity(
                    source_snapshot_sha256=source_sha,
                    rules_sha256=rules_sha,
                    building_profile_version=1,
                    cell_size_meters=rules.cell_size_meters,
                    halo_cells=rules.halo_cells,
                    minimum_samples=rules.minimum_samples,
                ),
            )
            calibration_cache.materialize_cells(sample_cells, {})
            block_cache_identity = write_block_cache_identity(
                root,
                source_sha,
                rules_sha,
                calibration_cache.key,
                calibration_cache.key_root / "manifest.json",
            )
            output = root / "map"
            rendered = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "extract_features.py"),
                    "0",
                    "0",
                    "0.02",
                    "0.02",
                    str(prefix),
                    str(output),
                    "--renderer-format",
                    "3",
                    "--preferred-language",
                    "en",
                    "--scope-plan",
                    str(scope_path),
                    "--calibration-manifest",
                    str(calibration_cache.key_root / "manifest.json"),
                    "--calibration-source-sha256",
                    source_sha,
                    "--building-block-cache-root",
                    str(root / "block-cache"),
                    "--building-block-cache-identity",
                    str(block_cache_identity),
                ],
                cwd=ROOT / "scripts",
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(
                rendered.returncode,
                0,
                rendered.stdout + rendered.stderr,
            )
            stats = json.loads(
                next(
                    line for line in rendered.stdout.splitlines()
                    if line.startswith("BUILDING_STATS:")
                ).removeprefix("BUILDING_STATS:")
            )
            self.assertEqual(stats["partCount"], 1)
            self.assertEqual(stats["relationAssociationCount"], 1)
            self.assertTrue(list(output.rglob("*.fmb")))

    def test_target_three_cli_emits_closed_line_parts_and_edge_blocks(self):
        host_font = next(
            (path for path in HOST_FONT_CANDIDATES if path.is_file()),
            None,
        )
        self.assertIsNotNone(host_font, "host font fixture is unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            prefix = root / "features"
            output = root / "map"
            (root / "features_lines.geojson").write_text(
                json.dumps(
                    {
                        "type": "FeatureCollection",
                        "features": [
                            {
                                "type": "Feature",
                                "properties": {
                                    "osm_id": 20,
                                    "other_tags": (
                                        '"building:part"=>"yes",'
                                        '"height"=>"12"'
                                    ),
                                },
                                "geometry": {
                                    "type": "LineString",
                                    "coordinates": [
                                        [200, 200],
                                        [800, 200],
                                        [800, 800],
                                        [200, 800],
                                        [200, 200],
                                    ],
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (root / "features_polygons.geojson").write_text(
                json.dumps(
                    {
                        "type": "FeatureCollection",
                        "features": [
                            {
                                "type": "Feature",
                                "properties": {
                                    "osm_way_id": 10,
                                    "building": "yes",
                                    "other_tags": '"height"=>"20"',
                                },
                                "geometry": {
                                    "type": "MultiPolygon",
                                    "coordinates": [[[
                                        [100, 100],
                                        [900, 100],
                                        [900, 900],
                                        [100, 900],
                                        [100, 100],
                                    ]]],
                                },
                            },
                            {
                                "type": "Feature",
                                "properties": {
                                    "osm_way_id": 30,
                                    "building": "yes",
                                    "other_tags": '"height"=>"10"',
                                },
                                "geometry": {
                                    "type": "MultiPolygon",
                                    "coordinates": [[[
                                        [8193, 100],
                                        [8199, 100],
                                        [8199, 106],
                                        [8193, 106],
                                        [8193, 100],
                                    ]]],
                                },
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (root / "features_building_relations.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "partParents": {"w20": "w10"},
                        "relations": 1,
                        "ambiguousParts": 0,
                    }
                ),
                encoding="utf-8",
            )

            environment = os.environ.copy()
            environment.update(
                {
                    "OBC_LABEL_LATIN_FONT": str(host_font),
                    "OBC_LABEL_CJK_FONT": str(host_font),
                }
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "extract_features.py"),
                    str(math.degrees(100 / EARTH_RADIUS_METERS)),
                    "0",
                    str(math.degrees(8200 / EARTH_RADIUS_METERS)),
                    str(
                        math.degrees(
                            2 * math.atan(math.exp(1000 / EARTH_RADIUS_METERS))
                            - math.pi / 2
                        )
                    ),
                    str(prefix),
                    str(output),
                    "--renderer-format",
                    "3",
                    "--preferred-language",
                    "en",
                ],
                cwd=ROOT / "scripts",
                check=False,
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            stats_line = next(
                line for line in result.stdout.splitlines()
                if line.startswith("BUILDING_STATS:")
            )
            stats = json.loads(stats_line.removeprefix("BUILDING_STATS:"))
            self.assertEqual(stats["partCount"], 1)
            self.assertEqual(stats["relationAssociationCount"], 1)
            self.assertEqual(stats["recordCount"], 3)
            blocks = list(output.rglob("*.fmb"))
            self.assertEqual(len(blocks), 2)
            self.assertTrue(
                all(block.read_bytes()[:4] == b"FMB\x04" for block in blocks)
            )
            self.assertTrue((output / "assets" / "street-labels.fma").is_file())

            rules, rules_sha = load_rules(
                ROOT / "conf" / "building_height_rules.yaml"
            )
            source_sha = "1" * 64
            calibration_cache = CalibrationCache(
                root / "cache",
                CalibrationIdentity(
                    source_snapshot_sha256=source_sha,
                    rules_sha256=rules_sha,
                    building_profile_version=1,
                    cell_size_meters=rules.cell_size_meters,
                    halo_cells=rules.halo_cells,
                    minimum_samples=rules.minimum_samples,
                ),
            )
            sample_cells = [
                (x, y) for x in range(-1, 3) for y in range(-1, 2)
            ]
            calibration_cache.materialize_cells(sample_cells, {})
            block_cache_identity = write_block_cache_identity(
                root,
                source_sha,
                rules_sha,
                calibration_cache.key,
                calibration_cache.key_root / "manifest.json",
            )
            scope = {
                "schemaVersion": 1,
                "policy": {
                    "policyVersion": 5,
                    "blockGridVersion": 1,
                    "blockSizeMeters": 4096,
                    "selectionSemantics": "complete_blocks_no_selection_edge_clipping",
                    "geometryBufferMeters": 256,
                    "relationRetryBufferMeters": 512,
                    "maxGeometryBufferMeters": 2048,
                },
                "outputBlocks": [
                    {"x": 0, "y": 0, "boundsMeters": [0, 0, 4096, 4096]}
                ],
                "calibration": {
                    "cellSizeMeters": rules.cell_size_meters,
                    "haloCells": rules.halo_cells,
                    "minimumSamples": rules.minimum_samples,
                    "sampleCells": [list(cell) for cell in sample_cells],
                },
            }
            scope_path = root / "scope-plan.json"
            scope_path.write_bytes(
                canonical_json(
                    {
                        **scope,
                        "scopePlanSha256": hashlib.sha256(
                            canonical_json(scope)
                        ).hexdigest(),
                    }
                )
                + b"\n"
            )
            scope_sha = hashlib.sha256(canonical_json(scope)).hexdigest()
            (root / "features_building_relations.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "partParents": {"w20": "w10"},
                        "relations": 1,
                        "ambiguousParts": 0,
                        "closureAudit": {
                            "closureRelationCount": 1,
                            "closureWayCount": 2,
                            "closureNodeCount": 8,
                            "relationRetryCount": 0,
                            "candidateCount": 2,
                            "sourceIndexKey": "2" * 64,
                            "sourceSnapshotSha256": source_sha,
                            "scopePlanSha256": scope_sha,
                        },
                    }
                ),
                encoding="utf-8",
            )
            selection_path = root / "selection.geojson"
            selection_path.write_text(
                json.dumps(
                    {
                        "type": "Polygon",
                        "coordinates": [[
                            [math.degrees(400 / EARTH_RADIUS_METERS), 0.0005],
                            [math.degrees(600 / EARTH_RADIUS_METERS), 0.0005],
                            [math.degrees(600 / EARTH_RADIUS_METERS), 0.0010],
                            [math.degrees(400 / EARTH_RADIUS_METERS), 0.0010],
                            [math.degrees(400 / EARTH_RADIUS_METERS), 0.0005],
                        ]],
                    }
                )
            )
            selected_output = root / "selected-map"
            selected_command = [
                    sys.executable,
                    str(ROOT / "scripts" / "extract_features.py"),
                    str(math.degrees(100 / EARTH_RADIUS_METERS)),
                    "0",
                    str(math.degrees(8200 / EARTH_RADIUS_METERS)),
                    str(
                        math.degrees(
                            2 * math.atan(math.exp(1000 / EARTH_RADIUS_METERS))
                            - math.pi / 2
                        )
                    ),
                    str(prefix),
                    str(selected_output),
                    "--renderer-format", "3",
                    "--preferred-language", "en",
                    "--scope-plan", str(scope_path),
                    "--selection-geometry", str(selection_path),
                    "--calibration-manifest",
                    str(calibration_cache.key_root / "manifest.json"),
                    "--calibration-source-sha256", source_sha,
                    "--building-block-cache-root", str(root / "block-cache"),
                    "--building-block-cache-identity", str(block_cache_identity),
                ]
            selected_result = subprocess.run(
                selected_command,
                cwd=ROOT / "scripts",
                check=False,
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(
                selected_result.returncode,
                0,
                f"stdout:\n{selected_result.stdout}\nstderr:\n{selected_result.stderr}",
            )
            selected_stats = json.loads(
                next(
                    line for line in selected_result.stdout.splitlines()
                    if line.startswith("BUILDING_STATS:")
                ).removeprefix("BUILDING_STATS:")
            )
            scope_lines = [
                line for line in selected_result.stdout.splitlines()
                if line.startswith("BUILDING_SCOPE:")
            ]
            self.assertEqual(len(scope_lines), 1)
            scope_stats = json.loads(scope_lines[0].removeprefix("BUILDING_SCOPE:"))
            self.assertEqual(scope_stats["scopePlanSha256"], scope_sha)
            self.assertEqual(scope_stats["outputBlockCount"], 1)
            self.assertEqual(selected_stats["recordCount"], 2)
            self.assertEqual(selected_stats["calibrationSource"], "sourceSnapshotCache")
            self.assertEqual(len(list(selected_output.rglob("*.fmb"))), 1)
            self.assertEqual(selected_stats["blockCache"]["initialMissCount"], 1)
            self.assertEqual(selected_stats["blockCache"]["builtCount"], 1)

            warm_output = root / "selected-map-warm"
            warm_command = list(selected_command)
            warm_command[warm_command.index(str(selected_output))] = str(warm_output)
            warm_result = subprocess.run(
                warm_command,
                cwd=ROOT / "scripts",
                check=False,
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(
                warm_result.returncode,
                0,
                f"stdout:\n{warm_result.stdout}\nstderr:\n{warm_result.stderr}",
            )
            warm_stats = json.loads(
                next(
                    line for line in warm_result.stdout.splitlines()
                    if line.startswith("BUILDING_STATS:")
                ).removeprefix("BUILDING_STATS:")
            )
            self.assertEqual(warm_stats["blockCache"]["initialHitCount"], 1)
            self.assertEqual(warm_stats["blockCache"]["initialMissCount"], 0)
            self.assertEqual(warm_stats["blockCache"]["builtCount"], 0)
            self.assertEqual(
                next(selected_output.rglob("*.fmb")).read_bytes(),
                next(warm_output.rglob("*.fmb")).read_bytes(),
            )

            invalid_scope = json.loads(json.dumps(scope))
            invalid_scope["policy"].pop("selectionSemantics")
            invalid_scope_path = root / "invalid-scope-plan.json"
            invalid_scope_path.write_bytes(
                canonical_json(
                    {
                        **invalid_scope,
                        "scopePlanSha256": hashlib.sha256(
                            canonical_json(invalid_scope)
                        ).hexdigest(),
                    }
                )
                + b"\n"
            )
            invalid_command = list(selected_command)
            invalid_command[
                invalid_command.index(str(scope_path))
            ] = str(invalid_scope_path)
            invalid_result = subprocess.run(
                invalid_command,
                cwd=ROOT / "scripts",
                check=False,
                env=environment,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(invalid_result.returncode, 0)
            self.assertIn(
                "selection semantics are unsupported",
                invalid_result.stdout + invalid_result.stderr,
            )


if __name__ == "__main__":
    unittest.main()
