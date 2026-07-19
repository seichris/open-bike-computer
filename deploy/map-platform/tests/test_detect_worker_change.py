from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "detect_worker_change.py"
SPEC = importlib.util.spec_from_file_location("detect_worker_change", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
detect_worker_change = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = detect_worker_change
SPEC.loader.exec_module(detect_worker_change)


class DetectWorkerChangeTests(unittest.TestCase):
    def test_all_declared_worker_roots_are_classified_as_worker_changes(self) -> None:
        for root in detect_worker_change.WORKER_SOURCE_ROOTS:
            with self.subTest(root=root):
                self.assertTrue(detect_worker_change.worker_inputs_changed([root]))
                if "." not in Path(root).name:
                    self.assertTrue(
                        detect_worker_change.worker_inputs_changed([f"{root}/child.py"])
                    )

    def test_control_plane_and_deployment_paths_do_not_move_worker(self) -> None:
        self.assertFalse(
            detect_worker_change.worker_inputs_changed(
                [
                    ".github/workflows/map-platform-image.yml",
                    "config/map-stream-rollout-approvals.json",
                    "config/map-stream-trust.json",
                    "deploy/map-platform/compose.yaml",
                    "backend/README.md",
                    "backend/docker-compose.yml",
                ]
            )
        )

    def test_image_scope_matches_workflow_build_inputs(self) -> None:
        for root in detect_worker_change.IMAGE_INPUT_ROOTS:
            with self.subTest(root=root):
                self.assertTrue(detect_worker_change.image_inputs_changed([root]))
                if "." not in Path(root).name:
                    self.assertTrue(
                        detect_worker_change.image_inputs_changed([f"{root}/child"])
                    )
        self.assertFalse(
            detect_worker_change.image_inputs_changed(
                ["docs/readme.md", "deploy/map-platform/compose.yaml"]
            )
        )

    def test_promotion_scope_includes_policy_and_ci_inputs(self) -> None:
        for root in detect_worker_change.PROMOTION_INPUT_ROOTS:
            with self.subTest(root=root):
                self.assertTrue(
                    detect_worker_change.promotion_inputs_changed([root])
                )
        self.assertFalse(
            detect_worker_change.promotion_inputs_changed(
                ["docs/readme.md", "deploy/map-platform/compose.yaml"]
            )
        )

    def test_unknown_git_range_is_conservative(self) -> None:
        self.assertIsNone(
            detect_worker_change.git_changed_paths(
                detect_worker_change.REPO_ROOT,
                "",
                "a" * 40,
            )
        )
        self.assertIsNone(
            detect_worker_change.git_changed_paths(
                detect_worker_change.REPO_ROOT,
                "0" * 40,
                "a" * 40,
            )
        )

    def test_repository_escape_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "outside the repository"):
            detect_worker_change.worker_inputs_changed(["../backend/map_platform/api.py"])

    def test_rename_out_of_worker_root_reports_removed_source_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
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
            source = repo / "backend" / "map_platform" / "worker.py"
            source.parent.mkdir(parents=True)
            source.write_text("worker = True\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "worker"], cwd=repo, check=True)
            before = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            destination = repo / "docs" / "worker.py"
            destination.parent.mkdir()
            source.rename(destination)
            subprocess.run(["git", "add", "-A"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "move worker"], cwd=repo, check=True)
            after = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            paths = detect_worker_change.git_changed_paths(repo, before, after)
            self.assertIsNotNone(paths)
            self.assertIn("backend/map_platform/worker.py", paths)
            self.assertTrue(detect_worker_change.worker_inputs_changed(paths or []))

    def test_accumulated_range_keeps_worker_change_before_control_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
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
            worker = repo / "backend" / "map_platform" / "worker.py"
            worker.parent.mkdir(parents=True)
            worker.write_text("version = 0\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "production"], cwd=repo, check=True)
            production = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            worker.write_text("version = 1\n", encoding="utf-8")
            subprocess.run(["git", "commit", "-qam", "worker candidate"], cwd=repo, check=True)
            worker_candidate = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            docs = repo / "docs"
            docs.mkdir()
            (docs / "control.md").write_text("control only\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "control"], cwd=repo, check=True)
            control = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            adjacent = detect_worker_change.git_changed_paths(
                repo,
                worker_candidate,
                control,
            )
            accumulated = detect_worker_change.git_changed_paths(
                repo,
                production,
                control,
            )
            self.assertFalse(detect_worker_change.worker_inputs_changed(adjacent or []))
            self.assertTrue(detect_worker_change.worker_inputs_changed(accumulated or []))


if __name__ == "__main__":
    unittest.main()
