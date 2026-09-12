import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "pbf_to_geojson.sh"


class PbfToGeoJSONTests(unittest.TestCase):
    def test_target_four_adds_the_projected_points_layer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            log_path = root / "ogr2ogr.log"

            ogr2ogr = bin_dir / "ogr2ogr"
            ogr2ogr.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >> "$OGR2OGR_LOG"\n',
                encoding="utf-8",
            )
            ogr2ogr.chmod(0o755)
            python = bin_dir / "python"
            python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            python.chmod(0o755)

            env = dict(os.environ)
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["OGR2OGR_LOG"] = str(log_path)
            subprocess.run(
                [
                    "bash",
                    str(SCRIPT),
                    "103.6",
                    "1.1",
                    "104.1",
                    "1.5",
                    str(root / "source.osm.pbf"),
                    str(root / "features"),
                    "--renderer-format",
                    "4",
                ],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            calls = log_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(calls), 3)
            self.assertTrue(calls[0].endswith(" lines"))
            self.assertTrue(calls[1].endswith(" multipolygons"))
            self.assertTrue(calls[2].endswith(" points"))
            self.assertIn("features_points.geojson", calls[2])

    def test_ogr_uses_interleaved_reading_for_osm_layers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            log_path = root / "ogr2ogr.log"

            ogr2ogr = bin_dir / "ogr2ogr"
            ogr2ogr.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >> "$OGR2OGR_LOG"\n',
                encoding="utf-8",
            )
            ogr2ogr.chmod(0o755)

            python = bin_dir / "python"
            python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            python.chmod(0o755)

            env = dict(os.environ)
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["OGR2OGR_LOG"] = str(log_path)
            subprocess.run(
                [
                    "bash",
                    str(SCRIPT),
                    "103.6",
                    "1.1",
                    "104.1",
                    "1.5",
                    str(root / "source.osm.pbf"),
                    str(root / "features"),
                ],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            calls = log_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(calls), 2)
            for call in calls:
                self.assertIn("--config OGR_INTERLEAVED_READING YES", call)
                self.assertNotIn("OSM_CONFIG_FILE", call)

    def test_selected_mode_reports_all_bounded_closure_ways(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            log_path = root / "ogr2ogr.log"

            ogr2ogr = bin_dir / "ogr2ogr"
            ogr2ogr.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >> "$OGR2OGR_LOG"\n',
                encoding="utf-8",
            )
            ogr2ogr.chmod(0o755)

            python = bin_dir / "python"
            python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            python.chmod(0o755)

            env = dict(os.environ)
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["OGR2OGR_LOG"] = str(log_path)
            subprocess.run(
                [
                    "bash",
                    str(SCRIPT),
                    "103.6",
                    "1.1",
                    "104.1",
                    "1.5",
                    str(root / "source.osm.pbf"),
                    str(root / "features"),
                    str(root / "source-index-manifest.json"),
                    str(root / "scope-plan.json"),
                    "0",
                ],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            calls = log_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(calls), 2)
            expected_config = (
                ROOT / "conf" / "osmconf-selected-building-closure.ini"
            )
            for call in calls:
                self.assertIn("--config OGR_INTERLEAVED_READING YES", call)
                self.assertIn(
                    f"--config OSM_CONFIG_FILE {expected_config}",
                    call,
                )

    def test_selected_mode_passes_verified_closure_plan_to_relation_audit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            python_log = root / "python.log"

            ogr2ogr = bin_dir / "ogr2ogr"
            ogr2ogr.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            ogr2ogr.chmod(0o755)

            python = bin_dir / "python"
            python.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >> "$PYTHON_LOG"\n',
                encoding="utf-8",
            )
            python.chmod(0o755)

            env = dict(os.environ)
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["PYTHON_LOG"] = str(python_log)
            closure_plan = root / "closure-plan.json"
            subprocess.run(
                [
                    "bash",
                    str(SCRIPT),
                    "103.6",
                    "1.1",
                    "104.1",
                    "1.5",
                    str(root / "source.osm.pbf"),
                    str(root / "features"),
                    str(root / "source-index-manifest.json"),
                    str(root / "scope-plan.json"),
                    "0",
                    str(closure_plan),
                ],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertIn(
                f"--closure-plan {closure_plan}",
                python_log.read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main()
