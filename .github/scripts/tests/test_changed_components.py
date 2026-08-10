from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "changed_components.py"
SPEC = importlib.util.spec_from_file_location("changed_components", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
changed_components = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(changed_components)


class ChangedComponentsTests(unittest.TestCase):
    def test_docs_only_change_skips_product_jobs(self) -> None:
        self.assertEqual(
            {
                "firmware": False,
                "ios": False,
                "map_backend": False,
                "osm": False,
            },
            changed_components.classify_paths(["README.md", "docs/README.md"]),
        )

    def test_each_product_tree_selects_its_jobs(self) -> None:
        firmware = changed_components.classify_paths(["esp32/src/main.cpp"])
        ios = changed_components.classify_paths(["ios-app/BikeComputer/App.swift"])
        backend = changed_components.classify_paths(
            ["map-platform/backend/map_platform/api.py"]
        )

        self.assertTrue(firmware["firmware"])
        self.assertFalse(firmware["ios"])
        self.assertTrue(ios["ios"])
        self.assertFalse(ios["firmware"])
        self.assertTrue(backend["map_backend"])
        self.assertFalse(backend["osm"])

    def test_osm_changes_also_validate_the_backend_image(self) -> None:
        selected = changed_components.classify_paths(
            ["tools/OSM_Extract/scripts/extract_features.py"]
        )

        self.assertTrue(selected["osm"])
        self.assertTrue(selected["map_backend"])

    def test_ci_router_change_runs_every_component(self) -> None:
        selected = changed_components.classify_paths(
            [".github/scripts/changed_components.py"]
        )

        self.assertTrue(all(selected.values()))

    def test_manual_dispatch_runs_every_component(self) -> None:
        selected = changed_components.classify_paths([], run_all=True)

        self.assertTrue(all(selected.values()))

    def test_map_scope_runs_only_map_components(self) -> None:
        selected = changed_components.select_scope("map")

        self.assertIsNotNone(selected)
        assert selected is not None
        self.assertFalse(selected["firmware"])
        self.assertFalse(selected["ios"])
        self.assertTrue(selected["map_backend"])
        self.assertTrue(selected["osm"])

    def test_pull_request_uses_merge_base_diff(self) -> None:
        base = "a" * 40
        head = "b" * 40

        self.assertEqual(
            (
                "git",
                "diff",
                "--no-renames",
                "--name-only",
                "-z",
                f"{base}...{head}",
                "--",
            ),
            changed_components.git_diff_command("pull_request", base, head),
        )

    def test_new_ref_push_uses_root_diff(self) -> None:
        head = "b" * 40

        self.assertEqual(
            (
                "git",
                "diff-tree",
                "--no-renames",
                "--root",
                "--no-commit-id",
                "--name-only",
                "-r",
                "-z",
                head,
                "--",
            ),
            changed_components.git_diff_command(
                "push", changed_components.ZERO_SHA, head
            ),
        )

    def test_invalid_revision_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "base must be"):
            changed_components.git_diff_command("push", "main", "b" * 40)


if __name__ == "__main__":
    unittest.main()
