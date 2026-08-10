from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW_ROOT = REPO_ROOT / ".github" / "workflows"
CORE_FIRMWARE_TARGETS = {
    "WAVESHARE_AMOLED_175",
    "WAVESHARE_AMOLED_175_PRODUCTION",
    "WAVESHARE_AMOLED_206",
    "WAVESHARE_AMOLED_206_PRODUCTION",
}
DIAGNOSTIC_FIRMWARE_TARGETS = {
    "WAVESHARE_AMOLED_175_MAPIO_DIAGNOSTICS",
    "WAVESHARE_AMOLED_175_POWER_METRICS",
    "WAVESHARE_AMOLED_175_LIGHT_SLEEP",
    "WAVESHARE_AMOLED_206_MAPIO_DIAGNOSTICS",
    "WAVESHARE_AMOLED_206_DISPLAY_TEST",
    "WAVESHARE_AMOLED_206_POWER_METRICS",
    "WAVESHARE_AMOLED_206_LIGHT_SLEEP",
}
SHARED_CONTRACT_PATHS = {
    "docs/app-store-privacy-disclosures.md",
    "docs/device-ownership-test-vectors.json",
    "docs/firmware-battery-life-hardware-validation.md",
    "docs/firmware-map-memory-diagnostics.md",
    "docs/firmware-map-render-scheduler.md",
    "docs/firmware-map-rendering-psram.md",
    "docs/releases/watchos-workout-companion.md",
}


def workflow_source(filename: str) -> str:
    return (WORKFLOW_ROOT / filename).read_text(encoding="utf-8")


def workflow_paths(root: Path = WORKFLOW_ROOT) -> tuple[Path, ...]:
    return tuple(sorted((*root.glob("*.yml"), *root.glob("*.yaml"))))


def workflow_sources(root: Path = WORKFLOW_ROOT) -> tuple[tuple[str, str], ...]:
    return tuple(
        (path.name, path.read_text(encoding="utf-8"))
        for path in workflow_paths(root)
    )


def firmware_builder_lines(source: str) -> tuple[str, ...]:
    return tuple(
        line.strip()
        for line in source.splitlines()
        if "build_firmware.py" in line and not line.lstrip().startswith("#")
    )


def mapping_block(source: str, key: str, *, indent: int) -> str:
    lines = source.splitlines()
    marker = f"{' ' * indent}{key}:"
    try:
        start = lines.index(marker)
    except ValueError as error:
        raise AssertionError(f"missing YAML mapping key: {key}") from error

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        line_indent = len(line) - len(line.lstrip())
        if line_indent <= indent:
            end = index
            break
    return "\n".join(lines[start:end])


def child_mapping_blocks(
    source: str, parent_key: str, *, indent: int
) -> tuple[tuple[str, str], ...]:
    parent_lines = mapping_block(source, parent_key, indent=indent).splitlines()
    child_indent = indent + 2
    children: list[tuple[str, int]] = []
    for index, line in enumerate(parent_lines[1:], start=1):
        line_indent = len(line) - len(line.lstrip())
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_-]*):", line.strip())
        if line_indent == child_indent and match:
            children.append((match.group(1), index))

    blocks = []
    for child_index, (key, start) in enumerate(children):
        end = (
            children[child_index + 1][1]
            if child_index + 1 < len(children)
            else len(parent_lines)
        )
        blocks.append((key, "\n".join(parent_lines[start:end])))
    return tuple(blocks)


def firmware_builder_jobs(source: str) -> tuple[tuple[str, str], ...]:
    return tuple(
        (job, block)
        for job, block in child_mapping_blocks(source, "jobs", indent=0)
        if firmware_builder_lines(block)
    )


def matrix_targets(source: str) -> set[str]:
    return set(
        re.findall(r"^\s+- (WAVESHARE_AMOLED_[A-Z0-9_]+)$", source, re.MULTILINE)
    )


class WorkflowPolicyTests(unittest.TestCase):
    def test_default_and_diagnostic_firmware_matrices_stay_separate(self) -> None:
        default_targets = matrix_targets(workflow_source("ci.yml"))
        diagnostic_targets = matrix_targets(
            workflow_source("firmware-diagnostics.yml")
        )

        self.assertEqual(CORE_FIRMWARE_TARGETS, default_targets)
        self.assertEqual(DIAGNOSTIC_FIRMWARE_TARGETS, diagnostic_targets)

    def test_feature_branch_pushes_do_not_duplicate_pull_request_ci(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertIn("  push:\n    branches:\n      - main\n", general_ci)
        self.assertIn("  pull_request:\n", general_ci)
        self.assertIn("  cancel-in-progress: true\n", general_ci)

    def test_concurrency_separates_events_and_manual_scopes(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertIn("github.event_name", general_ci)
        self.assertIn("inputs.scope || 'auto'", general_ci)

    def test_partial_manual_runs_do_not_publish_the_protected_gate(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertIn("Manual CI Gate", general_ci)
        self.assertIn("refs/heads/deploy/map-platform-production", general_ci)
        self.assertIn("Validate the protected partial gate scope", general_ci)
        self.assertIn("':(exclude)map-platform/deploy/compose.yaml'", general_ci)

    def test_release_tags_use_one_gated_validation_orchestrator(self) -> None:
        general_ci = workflow_source("ci.yml")
        diagnostic_ci = workflow_source("firmware-diagnostics.yml")
        release = workflow_source("firmware-release.yml")

        self.assertIn("  workflow_call:\n", general_ci)
        self.assertIn("github.ref_type == 'tag'", general_ci)
        self.assertNotIn('      - "v*"', general_ci)
        self.assertIn("  workflow_call:\n", diagnostic_ci)
        self.assertNotIn('      - "v*"', diagnostic_ci)
        self.assertIn('      - "v*"', release)
        self.assertIn("uses: ./.github/workflows/ci.yml", release)
        self.assertIn(
            "uses: ./.github/workflows/firmware-diagnostics.yml", release
        )
        self.assertIn("      - build\n      - diagnostics\n      - validate\n", release)
        self.assertIn("  attestations: read\n", release)
        self.assertIn("  packages: read\n", release)

    def test_main_push_filter_includes_shared_contract_inputs(self) -> None:
        general_ci = workflow_source("ci.yml")

        for path in SHARED_CONTRACT_PATHS:
            with self.subTest(path=path):
                self.assertIn(f'      - "{path}"', general_ci)
        self.assertIn('      - "test-fixtures/fmb/**"', general_ci)
        self.assertIn('      - "tools/firmware_manifest.py"', general_ci)
        self.assertIn('      - "tools/tests/**"', general_ci)

    def test_promotion_contract_requires_the_aggregate_gate(self) -> None:
        agent_instructions = (REPO_ROOT / "AGENTS.md").read_text(encoding="utf-8")

        self.assertIn("Merge only after **CI Gate**", agent_instructions)
        self.assertNotIn("Merge only after **Map Backend**", agent_instructions)

    def test_host_tests_keep_a_clean_firmware_build_environment(self) -> None:
        general_ci = workflow_source("ci.yml")
        host_job = mapping_block(general_ci, "esp32-host", indent=2)

        self.assertNotIn("actions/setup-python", host_job)
        self.assertIn("python3-cryptography", host_job)
        self.assertIn("python3 -m unittest discover -s tools/tests", host_job)

    def test_host_job_mapping_stops_at_the_next_peer(self) -> None:
        source = (
            "jobs:\n"
            "  esp32-host:\n"
            "    steps:\n"
            "      - run: python3 -m unittest\n"
            "  unrelated:\n"
            "    uses: actions/setup-python@v7\n"
        )

        host_job = mapping_block(source, "esp32-host", indent=2)

        self.assertIn("python3 -m unittest", host_job)
        self.assertNotIn("actions/setup-python", host_job)

    def test_builder_scanner_includes_block_scalar_commands(self) -> None:
        source = (
            "steps:\n"
            "  - run: |\n"
            "      python tools/build_firmware.py WAVESHARE_AMOLED_175\n"
        )

        self.assertEqual(
            ("python tools/build_firmware.py WAVESHARE_AMOLED_175",),
            firmware_builder_lines(source),
        )

    def test_workflow_discovery_includes_yml_and_yaml(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            for filename in ("builder.yml", "release.yaml", "ignored.txt"):
                (root / filename).write_text("name: test\n", encoding="utf-8")

            self.assertEqual(
                ("builder.yml", "release.yaml"),
                tuple(path.name for path in workflow_paths(root)),
            )

    def test_builder_cache_association_stays_job_scoped(self) -> None:
        source = (
            "jobs:\n"
            "  cached-non-builder:\n"
            "    steps:\n"
            "      - uses: actions/cache@v6\n"
            "  uncached-builder:\n"
            "    steps:\n"
            "      - run: env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n"
        )

        self.assertEqual(
            (("uncached-builder", mapping_block(source, "uncached-builder", indent=2)),),
            firmware_builder_jobs(source),
        )
        self.assertNotIn("actions/cache", firmware_builder_jobs(source)[0][1])

    def test_every_firmware_builder_clears_library_overrides(self) -> None:
        builder_count = 0
        for workflow, source in workflow_sources():
            for job, block in firmware_builder_jobs(source):
                for command in firmware_builder_lines(block):
                    builder_count += 1
                    with self.subTest(
                        workflow=workflow, job=job, command=command
                    ):
                        self.assertIn(
                            "env -u LD_LIBRARY_PATH python tools/build_firmware.py",
                            command,
                        )
        self.assertGreater(builder_count, 0)

    def test_every_firmware_builder_reuses_verified_downloads(self) -> None:
        builder_jobs = tuple(
            (workflow, job, block)
            for workflow, source in workflow_sources()
            for job, block in firmware_builder_jobs(source)
        )
        self.assertTrue(builder_jobs)
        for workflow, job, block in builder_jobs:
            with self.subTest(workflow=workflow, job=job):
                self.assertIn("uses: actions/cache@v6", block)
                self.assertIn(".pio/open-bike-build/downloads", block)


if __name__ == "__main__":
    unittest.main()
