from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "export_pending_compose.py"
SPEC = importlib.util.spec_from_file_location("export_pending_compose", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
export_pending_compose = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = export_pending_compose
SPEC.loader.exec_module(export_pending_compose)


class ExportPendingComposeTests(unittest.TestCase):
    def commit_files(self, repo: Path, files: dict[str, str]) -> str:
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(
            ["git", "config", "user.email", "tests@example.com"],
            cwd=repo,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Tests"],
            cwd=repo,
            check=True,
        )
        for relative_path, contents in files.items():
            path = repo / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(
            ["git", "commit", "-qm", "fixture"],
            cwd=repo,
            check=True,
        )
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=repo,
            text=True,
        ).strip()

    def test_exports_legacy_path_from_pre_relocation_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            commit = self.commit_files(
                repo,
                {"deploy/map-platform/compose.yaml": "legacy\n"},
            )
            output = repo / "exported.yaml"

            selected = export_pending_compose.export_pending_compose(
                repo,
                commit,
                output,
            )

            self.assertEqual("deploy/map-platform/compose.yaml", selected)
            self.assertEqual("legacy\n", output.read_text(encoding="utf-8"))

    def test_prefers_relocated_path_when_both_exist(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            commit = self.commit_files(
                repo,
                {
                    "deploy/map-platform/compose.yaml": "legacy\n",
                    "map-platform/deploy/compose.yaml": "relocated\n",
                },
            )
            output = repo / "exported.yaml"

            selected = export_pending_compose.export_pending_compose(
                repo,
                commit,
                output,
            )

            self.assertEqual("map-platform/deploy/compose.yaml", selected)
            self.assertEqual("relocated\n", output.read_text(encoding="utf-8"))

    def test_rejects_commit_without_a_production_compose(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            commit = self.commit_files(repo, {"README.md": "fixture\n"})

            with self.assertRaisesRegex(
                FileNotFoundError,
                "neither the relocated nor legacy Compose path",
            ):
                export_pending_compose.export_pending_compose(
                    repo,
                    commit,
                    repo / "exported.yaml",
                )

    def test_rejects_malformed_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "full lowercase Git SHA"):
                export_pending_compose.export_pending_compose(
                    Path(directory),
                    "HEAD",
                    Path(directory) / "exported.yaml",
                )


if __name__ == "__main__":
    unittest.main()
