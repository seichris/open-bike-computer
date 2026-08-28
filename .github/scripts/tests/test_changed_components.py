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
                "firmware_build": False,
                "firmware_host": False,
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

        self.assertTrue(firmware["firmware_build"])
        self.assertTrue(firmware["firmware_host"])
        self.assertFalse(firmware["ios"])
        self.assertTrue(ios["ios"])
        self.assertFalse(ios["firmware_build"])
        self.assertFalse(ios["firmware_host"])
        self.assertTrue(backend["map_backend"])
        self.assertFalse(backend["osm"])

    def test_firmware_host_only_inputs_skip_board_builds(self) -> None:
        for path in (
            "esp32/README.md",
            "esp32/tools/tests/test_build_firmware.py",
            "tools/tests/test_future_release_tool.py",
            ".github/actions/require-immutable-releases/action.yml",
            ".github/workflows/firmware-release-candidate.yml",
            ".github/workflows/firmware-release.yml",
            "docs/firmware-build-provenance.md",
        ):
            with self.subTest(path=path):
                selected = changed_components.classify_paths([path])
                self.assertFalse(selected["firmware_build"])
                self.assertTrue(selected["firmware_host"])

    def test_osm_changes_also_validate_the_backend_image(self) -> None:
        selected = changed_components.classify_paths(
            ["tools/OSM_Extract/scripts/extract_features.py"]
        )

        self.assertTrue(selected["osm"])
        self.assertTrue(selected["map_backend"])

    def test_shared_fmb_fixture_selects_every_consumer(self) -> None:
        selected = changed_components.classify_paths(
            ["test-fixtures/fmb/golden_blocks.txt"]
        )

        self.assertEqual(
            {
                "firmware_build": False,
                "firmware_host": True,
                "ios": False,
                "map_backend": True,
                "osm": True,
            },
            selected,
        )

    def test_shared_ownership_fixture_selects_firmware_and_ios(self) -> None:
        selected = changed_components.classify_paths(
            ["docs/device-ownership-test-vectors.json"]
        )

        self.assertEqual(
            {
                "firmware_build": False,
                "firmware_host": True,
                "ios": True,
                "map_backend": False,
                "osm": False,
            },
            selected,
        )

    def test_shared_map_stream_fixture_selects_every_consumer(self) -> None:
        selected = changed_components.classify_paths(
            ["map-platform/backend/tests/fixtures/map_stream_v1_golden.txt"]
        )

        self.assertEqual(
            {
                "firmware_build": False,
                "firmware_host": True,
                "ios": True,
                "map_backend": True,
                "osm": False,
            },
            selected,
        )

    def test_contract_documents_select_their_consumers(self) -> None:
        firmware_contracts = (
            "docs/firmware-battery-life-hardware-validation.md",
            "docs/firmware-build-provenance.md",
            "docs/firmware-factory-release.md",
            "docs/firmware-map-memory-diagnostics.md",
            "docs/firmware-map-render-scheduler.md",
            "docs/firmware-map-rendering-psram.md",
            "docs/firmware-runtime-maintenance.md",
        )
        ios_contracts = (
            "docs/app-store-privacy-disclosures.md",
            "docs/releases/watchos-workout-companion.md",
        )

        for path in firmware_contracts:
            with self.subTest(path=path):
                selected = changed_components.classify_paths([path])
                self.assertFalse(selected["firmware_build"])
                self.assertTrue(selected["firmware_host"])
                self.assertFalse(selected["ios"])
        for path in ios_contracts:
            with self.subTest(path=path):
                selected = changed_components.classify_paths([path])
                self.assertTrue(selected["ios"])
                self.assertFalse(selected["firmware_build"])
                self.assertFalse(selected["firmware_host"])

    def test_firmware_manifest_generator_and_tests_select_both_consumers(self) -> None:
        for path in (
            "tools/firmware_manifest.py",
            "tools/tests/test_firmware_manifest.py",
        ):
            with self.subTest(path=path):
                self.assertEqual(
                    {
                        "firmware_build": False,
                        "firmware_host": True,
                        "ios": True,
                        "map_backend": False,
                        "osm": False,
                    },
                    changed_components.classify_paths([path]),
                )

    def test_release_tools_select_firmware_only(self) -> None:
        for path in (
            ".github/scripts/firmware_release_gate.py",
            "tools/factory_release_manifest.py",
            "tools/firmware_release_candidate.py",
            "tools/firmware-signing-requirements.txt",
            "tools/verify_github_release_assets.py",
        ):
            with self.subTest(path=path):
                self.assertEqual(
                    {
                        "firmware_build": False,
                        "firmware_host": True,
                        "ios": False,
                        "map_backend": False,
                        "osm": False,
                    },
                    changed_components.classify_paths([path]),
                )

    def test_runtime_workflows_select_firmware_only(self) -> None:
        for path in (
            ".github/workflows/firmware-runtime-performance.yml",
            ".github/workflows/firmware-runtime-publish.yml",
            ".github/workflows/firmware-runtime-refresh.yml",
        ):
            with self.subTest(path=path):
                selected = changed_components.classify_paths([path])
                self.assertFalse(selected["firmware_build"])
                self.assertTrue(selected["firmware_host"])
                self.assertFalse(selected["ios"])

    def test_future_root_tool_tests_select_the_firmware_host_job(self) -> None:
        for path in (
            "tools/tests/test_future_release_tool.py",
            "tools/tests/helpers.py",
            "tools/tests/fixtures/manifest.json",
        ):
            with self.subTest(path=path):
                self.assertEqual(
                    {
                        "firmware_build": False,
                        "firmware_host": True,
                        "ios": False,
                        "map_backend": False,
                        "osm": False,
                    },
                    changed_components.classify_paths([path]),
                )

    def test_ride_diagnostics_tool_selects_its_host_test_job(self) -> None:
        selected = changed_components.classify_paths([
            "tools/ride_diagnostics.py"
        ])
        self.assertFalse(selected["firmware_build"])
        self.assertTrue(selected["firmware_host"])
        self.assertFalse(selected["ios"])

    def test_ci_router_change_runs_every_component(self) -> None:
        selected = changed_components.classify_paths(
            [".github/scripts/changed_components.py"]
        )

        self.assertTrue(all(selected.values()))

    def test_ci_policy_test_change_runs_in_the_selector_only(self) -> None:
        selected = changed_components.classify_paths(
            [".github/scripts/tests/test_workflow_policy.py"]
        )

        self.assertFalse(any(selected.values()))

    def test_manual_dispatch_runs_every_component(self) -> None:
        selected = changed_components.classify_paths([], run_all=True)

        self.assertTrue(all(selected.values()))

    def test_firmware_hardware_selection_is_explicit(self) -> None:
        targets_175 = (
            "WAVESHARE_AMOLED_175",
            "WAVESHARE_AMOLED_175_REMOTE_DEBUG",
            "WAVESHARE_AMOLED_175_PRODUCTION",
        )
        targets_206 = (
            "WAVESHARE_AMOLED_206",
            "WAVESHARE_AMOLED_206_REMOTE_DEBUG",
            "WAVESHARE_AMOLED_206_PRODUCTION",
        )

        self.assertEqual(
            targets_175,
            changed_components.select_firmware_targets("175"),
        )
        self.assertEqual(
            targets_206,
            changed_components.select_firmware_targets("206"),
        )
        self.assertEqual(
            targets_175 + targets_206,
            changed_components.select_firmware_targets("all"),
        )
        with self.assertRaisesRegex(ValueError, "unsupported firmware hardware"):
            changed_components.select_firmware_targets("unknown")

    def test_map_scope_runs_only_map_components(self) -> None:
        selected = changed_components.select_scope("map")

        self.assertIsNotNone(selected)
        assert selected is not None
        self.assertFalse(selected["firmware_build"])
        self.assertFalse(selected["firmware_host"])
        self.assertFalse(selected["ios"])
        self.assertTrue(selected["map_backend"])
        self.assertTrue(selected["osm"])

    def test_every_explicit_scope_has_the_expected_components(self) -> None:
        self.assertIsNone(changed_components.select_scope("auto"))
        self.assertEqual(
            {component: True for component in changed_components.COMPONENTS},
            changed_components.select_scope("all"),
        )
        firmware = changed_components.select_scope("firmware")
        assert firmware is not None
        self.assertTrue(firmware["firmware_build"])
        self.assertTrue(firmware["firmware_host"])
        self.assertEqual(2, sum(firmware.values()))

        ios = changed_components.select_scope("ios")
        assert ios is not None
        self.assertTrue(ios["ios"])
        self.assertEqual(1, sum(ios.values()))
        with self.assertRaisesRegex(ValueError, "unsupported CI scope"):
            changed_components.select_scope("unknown")

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

    def test_merge_group_uses_exact_queue_diff(self) -> None:
        base = "a" * 40
        head = "b" * 40

        self.assertEqual(
            (
                "git",
                "diff",
                "--no-renames",
                "--name-only",
                "-z",
                f"{base}..{head}",
                "--",
            ),
            changed_components.git_diff_command("merge_group", base, head),
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

    def test_normal_push_uses_two_dot_diff(self) -> None:
        base = "a" * 40
        head = "b" * 40

        self.assertEqual(
            (
                "git",
                "diff",
                "--no-renames",
                "--name-only",
                "-z",
                f"{base}..{head}",
                "--",
            ),
            changed_components.git_diff_command("push", base, head),
        )

    def test_manual_dispatch_does_not_compute_a_git_diff(self) -> None:
        self.assertIsNone(
            changed_components.git_diff_command(
                "workflow_dispatch", "not-needed", "not-needed"
            )
        )

    def test_unsupported_event_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "unsupported GitHub event"):
            changed_components.git_diff_command("schedule", "a" * 40, "b" * 40)

    def test_workflow_and_docker_inputs_select_their_components(self) -> None:
        firmware = changed_components.classify_paths(
            [".github/workflows/firmware-release.yml"]
        )
        map_workflow = changed_components.classify_paths(
            [".github/workflows/map-platform-image.yml"]
        )
        docker = changed_components.classify_paths([".dockerignore"])

        self.assertEqual(
            {
                "firmware_build": False,
                "firmware_host": True,
                "ios": False,
                "map_backend": False,
                "osm": False,
            },
            firmware,
        )
        self.assertTrue(map_workflow["map_backend"])
        self.assertTrue(map_workflow["osm"])
        self.assertTrue(docker["map_backend"])
        self.assertEqual(1, sum(docker.values()))

    def test_invalid_revision_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "base must be"):
            changed_components.git_diff_command("push", "main", "b" * 40)


if __name__ == "__main__":
    unittest.main()
