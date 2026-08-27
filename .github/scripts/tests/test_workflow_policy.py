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
REMOTE_DEBUG_FIRMWARE_TARGETS = {
    "WAVESHARE_AMOLED_175_REMOTE_DEBUG",
    "WAVESHARE_AMOLED_206_REMOTE_DEBUG",
}
DIAGNOSTIC_FIRMWARE_TARGETS = {
    *REMOTE_DEBUG_FIRMWARE_TARGETS,
    "WAVESHARE_AMOLED_175_MAPIO_DIAGNOSTICS",
    "WAVESHARE_AMOLED_175_DISPLAY_TEST",
    "WAVESHARE_AMOLED_175_POWER_METRICS",
    "WAVESHARE_AMOLED_175_LIGHT_SLEEP",
    "WAVESHARE_AMOLED_206_MAPIO_DIAGNOSTICS",
    "WAVESHARE_AMOLED_206_DISPLAY_TEST",
    "WAVESHARE_AMOLED_206_POWER_METRICS",
    "WAVESHARE_AMOLED_206_LIGHT_SLEEP",
}
JOB_KEY_PATTERN = re.compile(
    r'(?:"(?P<double>[A-Za-z_][A-Za-z0-9_-]*)"|'
    r"'(?P<single>[A-Za-z_][A-Za-z0-9_-]*)'|"
    r"(?P<plain>[A-Za-z_][A-Za-z0-9_-]*)):"
    r"\s*(?:&[A-Za-z_][A-Za-z0-9_-]*\s*)?(?:#.*)?"
)
CLEAN_BUILDER_PATTERN = re.compile(
    r"(?:run:\s*)?env -u LD_LIBRARY_PATH(?:\s+[A-Z_]+=\S*)* "
    r"python3? tools/build_firmware\.py\s+.+"
)


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
        if re.search(r"\bpython3?\s+tools/build_firmware\.py\b", line)
        and not line.lstrip().startswith("#")
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
        match = JOB_KEY_PATTERN.fullmatch(line.strip())
        if line_indent == child_indent and match:
            children.append((next(group for group in match.groups() if group), index))

    blocks = []
    for child_index, (key, start) in enumerate(children):
        end = (
            children[child_index + 1][1]
            if child_index + 1 < len(children)
            else len(parent_lines)
        )
        blocks.append((key, "\n".join(parent_lines[start:end])))
    return tuple(blocks)


def sequence_mapping_blocks(
    source: str, parent_key: str, *, indent: int
) -> tuple[str, ...]:
    parent_lines = mapping_block(source, parent_key, indent=indent).splitlines()
    item_indent = indent + 2
    item_starts = []
    for index, line in enumerate(parent_lines[1:], start=1):
        line_indent = len(line) - len(line.lstrip())
        if line_indent == item_indent and line.lstrip().startswith("-"):
            item_starts.append(index)

    blocks = []
    property_indent = item_indent + 2
    for item_index, start in enumerate(item_starts):
        end = (
            item_starts[item_index + 1]
            if item_index + 1 < len(item_starts)
            else len(parent_lines)
        )
        raw_lines = parent_lines[start:end]
        first_match = re.fullmatch(rf"\s{{{item_indent}}}-\s*(.*)", raw_lines[0])
        if not first_match:
            continue
        normalized = [first_match.group(1)]
        for line in raw_lines[1:]:
            normalized.append(
                line[property_indent:]
                if line.startswith(" " * property_indent)
                else line
            )
        blocks.append("\n".join(normalized))
    return tuple(blocks)


def is_verified_download_cache_step(step: str) -> bool:
    if not re.search(
        r"(?m)^uses:\s*actions/cache@v6\s*(?:#.*)?$",
        step,
    ):
        return False
    if re.search(r"(?m)^if:", step):
        return False
    try:
        with_block = mapping_block(step, "with", indent=0)
    except AssertionError:
        return False
    return bool(
        re.search(
            r"(?m)^\s{2}path:\s*(?:esp32/)?\.pio/open-bike-build/downloads"
            r"\s*(?:#.*)?$",
            with_block,
        )
    )


def firmware_builder_jobs(source: str) -> tuple[tuple[str, str], ...]:
    return tuple(
        (job, block)
        for job, block in child_mapping_blocks(source, "jobs", indent=0)
        if firmware_builder_lines(block)
    )


def firmware_builder_steps(job_block: str) -> tuple[str, ...]:
    return tuple(
        step
        for step in sequence_mapping_blocks(job_block, "steps", indent=4)
        if firmware_builder_lines(step)
    )


def matrix_targets(source: str) -> set[str]:
    return set(
        re.findall(r"^\s+- (WAVESHARE_AMOLED_[A-Z0-9_]+)$", source, re.MULTILINE)
    )


class WorkflowPolicyTests(unittest.TestCase):
    def assert_firmware_builders_clear_library_overrides(
        self, root: Path = WORKFLOW_ROOT
    ) -> None:
        builder_count = 0
        violations = []
        for workflow, source in workflow_sources(root):
            jobs = firmware_builder_jobs(source)
            all_commands = firmware_builder_lines(source)
            job_commands = tuple(
                command
                for _, block in jobs
                for command in firmware_builder_lines(block)
            )
            builder_count += len(all_commands)
            if sorted(all_commands) != sorted(job_commands):
                violations.append(
                    f"{workflow}: builder command exists outside a recognized job"
                )
            for job, block in jobs:
                steps = firmware_builder_steps(block)
                block_commands = firmware_builder_lines(block)
                step_commands = tuple(
                    command for step in steps for command in firmware_builder_lines(step)
                )
                if sorted(block_commands) != sorted(step_commands):
                    violations.append(
                        f"{workflow}:{job}: builder command exists outside a run step"
                    )
                for step in steps:
                    if re.search(r"(?m)^if:", step):
                        violations.append(
                            f"{workflow}:{job}: builder step is conditional"
                        )
                    for command in firmware_builder_lines(step):
                        if not CLEAN_BUILDER_PATTERN.fullmatch(command):
                            violations.append(
                                f"{workflow}:{job}: unsafe builder command: {command}"
                            )
        self.assertGreater(builder_count, 0)
        self.assertEqual((), tuple(violations))

    def assert_firmware_builders_reuse_verified_downloads(
        self, root: Path = WORKFLOW_ROOT
    ) -> None:
        builder_jobs = tuple(
            (workflow, job, block)
            for workflow, source in workflow_sources(root)
            if workflow
            not in {
                "firmware-runtime-refresh.yml",
                "firmware-runtime-performance.yml",
            }
            for job, block in firmware_builder_jobs(source)
        )
        self.assertTrue(builder_jobs)
        violations = []
        for workflow, job, block in builder_jobs:
            steps = sequence_mapping_blocks(block, "steps", indent=4)
            cache_indices = tuple(
                index
                for index, step in enumerate(steps)
                if is_verified_download_cache_step(step)
            )
            builder_indices = tuple(
                index
                for index, step in enumerate(steps)
                if firmware_builder_lines(step)
            )
            if not builder_indices or not all(
                any(cache_index < builder_index for cache_index in cache_indices)
                for builder_index in builder_indices
            ):
                violations.append(
                    f"{workflow}:{job}: missing active verified-download cache "
                    "before builder step"
                )
        self.assertEqual((), tuple(violations))

    def test_default_and_diagnostic_firmware_matrices_stay_separate(self) -> None:
        general_ci = workflow_source("ci.yml")
        router = (REPO_ROOT / ".github/scripts/changed_components.py").read_text(
            encoding="utf-8"
        )
        diagnostic_targets = matrix_targets(
            workflow_source("firmware-diagnostics.yml")
        )

        self.assertEqual(set(), matrix_targets(general_ci))
        self.assertIn(
            "target: ${{ fromJSON(needs.changes.outputs.firmware_targets) }}",
            general_ci,
        )
        for target in CORE_FIRMWARE_TARGETS | REMOTE_DEBUG_FIRMWARE_TARGETS:
            with self.subTest(target=target):
                self.assertIn(f'"{target}"', router)
        self.assertEqual(DIAGNOSTIC_FIRMWARE_TARGETS, diagnostic_targets)

    def test_pull_request_remote_debug_builds_verify_metrics_routes(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertIn(
            "Verify remote-debug artifacts include renderer metrics routes",
            general_ci,
        )
        self.assertIn("if: contains(matrix.target, '_REMOTE_DEBUG')", general_ci)
        self.assertIn('"/device-debug/v1/metrics"', general_ci)
        self.assertIn('"/device-debug/v1/metrics/window"', general_ci)
        self.assertIn('route.encode("utf-8") + b"\\0"', general_ci)

    def test_pull_request_ordinary_builds_verify_persistent_diagnostics_routes(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertIn(
            "Verify ordinary artifacts include persistent diagnostics capability",
            general_ci,
        )
        self.assertIn('"/device-diagnostics/v1/"', general_ci)
        self.assertIn('"storage_gap"', general_ci)
        self.assertIn(
            "if: ${{ !contains(matrix.target, '_REMOTE_DEBUG') }}",
            general_ci,
        )

    def test_ios_workout_suite_does_not_repeat_ride_diagnostics_xctest(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertNotIn("Run ride diagnostics XCTest target", general_ci)
        self.assertNotIn("run-ride-diagnostics-xctest.sh", general_ci)
        self.assertIn("Run workout contract tests on iOS", general_ci)
        self.assertIn("./scripts/run-workout-platform-tests.sh ios", general_ci)

    def test_release_container_owns_watch_build_validation(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertNotIn("Build watch app", general_ci)
        self.assertNotIn("-target BikeComputerWatch", general_ci)
        self.assertIn("Build Release app container", general_ci)
        self.assertIn("Validate Release app container", general_ci)
        self.assertIn("./scripts/verify-release-container.sh", general_ci)

    def test_ios_platform_tests_share_only_job_scoped_derived_data(self) -> None:
        general_ci = workflow_source("ci.yml")
        ios = mapping_block(general_ci, "ios", indent=2)

        self.assertIn(
            'CI_DERIVED_DATA_PATH=$RUNNER_TEMP/BikeComputerDerivedData',
            ios,
        )
        self.assertIn('>> "$GITHUB_ENV"', ios)
        self.assertNotIn("actions/cache", ios)

    def test_general_ci_does_not_repeat_after_merge(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertNotRegex(general_ci, r"(?m)^  push:")
        self.assertIn("  pull_request:\n", general_ci)
        self.assertIn("  workflow_call:\n", general_ci)
        self.assertIn("  workflow_dispatch:\n", general_ci)
        self.assertIn("  cancel-in-progress: true\n", general_ci)

    def test_ready_prs_and_merge_groups_restore_full_ci(self) -> None:
        general_ci = workflow_source("ci.yml")
        pull_request = mapping_block(general_ci, "pull_request", indent=2)
        merge_group = mapping_block(general_ci, "merge_group", indent=2)
        changes = mapping_block(general_ci, "changes", indent=2)

        for event_type in ("opened", "synchronize", "reopened", "ready_for_review"):
            with self.subTest(event_type=event_type):
                self.assertIn(f"      - {event_type}", pull_request)
        self.assertIn("      - checks_requested", merge_group)
        self.assertIn("heavy_ci: ${{ steps.policy.outputs.heavy_ci }}", changes)
        self.assertIn("PULL_REQUEST_DRAFT", changes)
        self.assertIn("github.event.merge_group.base_sha", changes)
        self.assertIn("github.event.merge_group.head_sha", changes)

    def test_draft_prs_keep_fast_checks_and_skip_heavy_jobs(self) -> None:
        general_ci = workflow_source("ci.yml")
        esp32 = mapping_block(general_ci, "esp32", indent=2)
        ios_fast = mapping_block(general_ci, "ios-fast", indent=2)
        ios = mapping_block(general_ci, "ios", indent=2)
        host = mapping_block(general_ci, "esp32-host", indent=2)
        gate = mapping_block(general_ci, "gate", indent=2)

        self.assertIn("needs.changes.outputs.heavy_ci == 'true'", esp32)
        self.assertIn("if: needs.changes.outputs.ios == 'true'", ios_fast)
        self.assertNotIn("needs.changes.outputs.heavy_ci", ios_fast)
        self.assertIn("needs.changes.outputs.heavy_ci == 'true'", ios)
        self.assertNotIn("needs.changes.outputs.heavy_ci", host)
        self.assertIn("- ios-fast", gate)
        self.assertIn("HEAVY_CI", gate)
        self.assertIn("IOS_FAST_RESULT", gate)
        self.assertIn(
            'test "$FIRMWARE_BUILD_CHANGED" = true && test "$HEAVY_CI" = true',
            gate,
        )
        self.assertIn(
            'test "$IOS_CHANGED" = true && test "$HEAVY_CI" = true',
            gate,
        )

    def test_concurrency_separates_events_and_manual_scopes(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertIn("github.event_name", general_ci)
        self.assertIn("inputs.scope || 'auto'", general_ci)
        self.assertIn("inputs.firmware_hardware || '175'", general_ci)

    def test_firmware_build_and_host_routing_stay_independent(self) -> None:
        general_ci = workflow_source("ci.yml")
        changes = mapping_block(general_ci, "changes", indent=2)
        esp32 = mapping_block(general_ci, "esp32", indent=2)
        host = mapping_block(general_ci, "esp32-host", indent=2)
        gate = mapping_block(general_ci, "gate", indent=2)

        self.assertIn(
            "firmware_build: ${{ steps.components.outputs.firmware_build }}",
            changes,
        )
        self.assertIn(
            "firmware_host: ${{ steps.components.outputs.firmware_host }}",
            changes,
        )
        self.assertIn(
            "firmware_targets: ${{ steps.components.outputs.firmware_targets }}",
            changes,
        )
        self.assertIn("needs.changes.outputs.firmware_build == 'true'", esp32)
        self.assertIn("needs.changes.outputs.heavy_ci == 'true'", esp32)
        self.assertIn(
            "if: needs.changes.outputs.firmware_host == 'true'",
            host,
        )
        self.assertIn("FIRMWARE_BUILD_CHANGED", gate)
        self.assertIn("FIRMWARE_HOST_CHANGED", gate)

    def test_206_firmware_ci_is_explicitly_dispatched(self) -> None:
        general_ci = workflow_source("ci.yml")
        instructions = (REPO_ROOT / "AGENTS.md").read_text(encoding="utf-8")

        self.assertEqual(2, general_ci.count('default: "175"'))
        self.assertIn('          - "206"', general_ci)
        self.assertIn("--firmware-hardware \"$FIRMWARE_HARDWARE\"", general_ci)
        self.assertIn("gh workflow run ci.yml", instructions)
        self.assertIn("firmware_hardware=206", instructions)
        self.assertIn("previous_run_id", instructions)
        self.assertIn("gh run watch", instructions)

    def test_partial_manual_runs_do_not_publish_the_protected_gate(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertIn("Manual CI Gate", general_ci)
        self.assertIn("refs/heads/deploy/map-platform-production", general_ci)
        self.assertIn("refs/heads/deploy/map-platform-development", general_ci)
        self.assertIn("Validate the protected partial gate scope", general_ci)
        self.assertIn('":(exclude)${deployment_lock}"', general_ci)
        self.assertIn(
            "deployment_lock=map-platform/deploy/compose.yaml",
            general_ci,
        )
        self.assertIn(
            "deployment_lock=map-platform/deploy/compose.development.yaml",
            general_ci,
        )

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
        self.assertIn("firmware_hardware: all", release)
        self.assertIn(
            "uses: ./.github/workflows/firmware-diagnostics.yml", release
        )
        self.assertIn("      - build\n      - diagnostics\n      - validate\n", release)
        release_permissions = mapping_block(release, "permissions", indent=0)
        self.assertIn("  attestations: read", release_permissions)
        self.assertIn("  contents: read", release_permissions)
        self.assertIn("  packages: read", release_permissions)
        publish_job = mapping_block(release, "publish", indent=2)
        self.assertIn("contents: write", publish_job)
        self.assertIn("pages: write", publish_job)

    def test_release_publishes_signed_factory_flash_bundles(self) -> None:
        release = workflow_source("firmware-release.yml")
        immutable_preflight = (
            REPO_ROOT
            / ".github"
            / "actions"
            / "require-immutable-releases"
            / "action.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("--factory-output-dir dist", release)
        self.assertNotIn("tools/package_factory_firmware.py", release)
        self.assertIn('"${target}.factory.tar.gz"', release)
        self.assertIn('"${target}.factory-bundle.json"', release)
        self.assertIn("tools/factory_release_manifest.py", release)
        self.assertIn(
            '--output "release-assets/${target}.factory-release.json"',
            release,
        )
        self.assertNotIn("find dist -name '*.bin'", release)
        self.assertNotIn("--clobber", release)
        self.assertIn("--draft", release)
        self.assertIn("tools/verify_github_release_assets.py", release)
        self.assertIn("already exists; refusing to replace assets", release)
        self.assertIn('"repos/${GITHUB_REPOSITORY}/releases/${release_id}"', release)
        self.assertIn("expected exactly one matching draft release", release)
        self.assertIn(
            "uses: ./.github/actions/require-immutable-releases", release
        )
        self.assertIn("--require-immutable", release)
        self.assertIn("X-GitHub-Api-Version: 2026-03-10", release)
        self.assertIn(
            "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1",
            immutable_preflight,
        )
        self.assertIn("permission-administration: read", immutable_preflight)
        self.assertIn(
            "repositories: ${{ github.event.repository.name }}", immutable_preflight
        )
        self.assertIn("/immutable-releases", immutable_preflight)
        self.assertIn("--require-hashes --only-binary=:all: --no-deps", release)
        self.assertIn("tools/firmware-signing-requirements.txt", release)
        self.assertNotIn("pip install --upgrade cryptography", release)

    def test_release_pages_recovery_accepts_only_attested_immutable_assets(self) -> None:
        release = workflow_source("firmware-release.yml")
        recovery = mapping_block(release, "recover-pages", indent=2)

        self.assertIn("  workflow_dispatch:\n", release)
        self.assertIn("if: github.event_name == 'workflow_dispatch'", recovery)
        self.assertIn("attestations: read", recovery)
        self.assertIn("contents: read", recovery)
        self.assertNotIn("contents: write", recovery)
        self.assertIn("must run from the default branch", recovery)
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", recovery)
        self.assertNotIn("ref: ${{ inputs.release_tag }}", recovery)
        self.assertIn("--require-immutable", recovery)
        self.assertIn('gh release verify "${RELEASE_TAG}"', recovery)
        self.assertIn('gh release verify-asset "${RELEASE_TAG}"', recovery)
        self.assertIn("actions/upload-pages-artifact@v3", recovery)
        self.assertIn("actions/deploy-pages@v4", recovery)
        self.assertNotIn("FIRMWARE_MANIFEST_SIGNING_PRIVATE_KEY", recovery)

    def test_production_ci_extracts_and_checks_factory_bundles(self) -> None:
        general_ci = workflow_source("ci.yml")

        self.assertIn("Verify production factory bundle packaging", general_ci)
        self.assertIn("if: endsWith(matrix.target, '_PRODUCTION')", general_ci)
        self.assertIn("--factory-output-dir", general_ci)
        self.assertNotIn("tools/package_factory_firmware.py", general_ci)
        self.assertIn("tar -xzf", general_ci)
        self.assertIn("sha256sum --check SHA256SUMS", general_ci)

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

    def test_runtime_refresh_reads_the_wrapped_candidate_contract(self) -> None:
        runtime_refresh = workflow_source("firmware-runtime-refresh.yml")

        self.assertRegex(runtime_refresh, r"(?m)^on:\n  workflow_dispatch:\n")
        self.assertNotRegex(runtime_refresh, r"(?m)^  pull_request:")
        self.assertEqual(
            runtime_refresh.count(
                'test -z "$(git status --porcelain=v1 --untracked-files=all)"'
            ),
            2,
        )
        self.assertIn("set -o pipefail", runtime_refresh)
        self.assertIn(
            'json.load(open(sys.argv[1]))["target"]["bundle"]["sha256"]',
            runtime_refresh,
        )
        self.assertNotIn(
            'json.load(open(sys.argv[1]))["bundle"]["sha256"]',
            runtime_refresh,
        )
        self.assertIn("tools/firmware_runtime_publication.py identity", runtime_refresh)
        self.assertIn("--factory-output-dir", runtime_refresh)
        self.assertIn("firmware-runtime-review-summary", runtime_refresh)

    def test_runtime_publication_is_manual_approval_gated_and_create_only(self) -> None:
        publication = workflow_source("firmware-runtime-publish.yml")
        validate = mapping_block(publication, "validate", indent=2)
        publish = mapping_block(publication, "publish", indent=2)

        self.assertRegex(publication, r"(?m)^on:\n  workflow_dispatch:\n")
        self.assertNotRegex(publication, r"(?m)^  (?:push|pull_request|schedule):")
        self.assertIn("  contents: read", publication)
        self.assertNotIn("contents: write", validate)
        self.assertIn("environment: firmware-runtime-publication", publish)
        self.assertIn("contents: write", publish)
        self.assertIn("candidate run does not match", validate)
        self.assertIn("requires human reviewers", validate)
        self.assertIn("verify-staged", publish)
        self.assertIn("tools/verify_github_release_assets.py", publish)
        self.assertIn("already exists; refusing to replace it", publish)
        self.assertIn(
            "uses: ./.github/actions/require-immutable-releases", publish
        )
        self.assertIn("--require-immutable", publish)
        self.assertIn("Runtime tag ${release_tag} already exists", publish)
        self.assertIn("runtime release tag does not bind", publish)
        self.assertIn("X-GitHub-Api-Version: 2026-03-10", publish)
        self.assertNotIn("--clobber", publication)

    def test_runtime_performance_gate_uses_five_native_samples(self) -> None:
        performance = workflow_source("firmware-runtime-performance.yml")

        self.assertIn("linux-x86_64-cp313", performance)
        self.assertIn("macos-arm64-cp313", performance)
        self.assertIn("for sample_index in 1 2 3 4 5", performance)
        self.assertIn("--runtime-check-only", performance)
        self.assertIn("check_firmware_runtime_performance.py", performance)

    def test_runtime_documentation_does_not_restore_the_removed_resolver_boundary(self) -> None:
        sources = "\n".join(
            (REPO_ROOT / path).read_text(encoding="utf-8")
            for path in ("AGENTS.md", "CONTRIBUTING.md", "esp32/README.md")
        )

        self.assertNotIn("first-run online Python dependency resolver", sources)
        self.assertNotIn("initial Python standard library", sources)
        self.assertIn("complete initial caller", sources)

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

    def test_quoted_and_commented_job_keys_cannot_hide_unsafe_builders(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "safe.yml").write_text(
                "jobs:\n"
                "  safe:\n"
                "    steps:\n"
                "      - run: env -u LD_LIBRARY_PATH python tools/build_firmware.py SAFE\n",
                encoding="utf-8",
            )
            (root / "fifth.yaml").write_text(
                "jobs:\n"
                '  "fifth-builder": # valid YAML comment\n'
                "    steps:\n"
                "      - run: python tools/build_firmware.py UNSAFE\n",
                encoding="utf-8",
            )

            with self.assertRaises(AssertionError):
                self.assert_firmware_builders_clear_library_overrides(root)

    def test_commented_peer_keys_cannot_lend_cache_to_builder(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "builder.yaml").write_text(
                "jobs:\n"
                "  uncached-builder:\n"
                "    steps:\n"
                "      - run: env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n"
                "  unrelated: # valid YAML comment\n"
                "    steps:\n"
                "      - uses: actions/cache@v6\n"
                "        with:\n"
                "          path: .pio/open-bike-build/downloads\n",
                encoding="utf-8",
            )

            with self.assertRaises(AssertionError):
                self.assert_firmware_builders_reuse_verified_downloads(root)

    def test_anchored_job_keys_cannot_hide_unsafe_builders(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "builder.yml").write_text(
                "jobs:\n"
                "  anchored-builder: &firmware_job\n"
                "    steps:\n"
                "      - run: python tools/build_firmware.py UNSAFE\n",
                encoding="utf-8",
            )

            with self.assertRaises(AssertionError):
                self.assert_firmware_builders_clear_library_overrides(root)

    def test_commented_cache_lines_cannot_satisfy_builder_policy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "builder.yml").write_text(
                "jobs:\n"
                "  uncached-builder:\n"
                "    steps:\n"
                "      # - uses: actions/cache@v6\n"
                "      #   with:\n"
                "      #     path: .pio/open-bike-build/downloads\n"
                "      - run: env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n",
                encoding="utf-8",
            )

            with self.assertRaises(AssertionError):
                self.assert_firmware_builders_reuse_verified_downloads(root)

    def test_unrelated_yaml_fields_cannot_satisfy_builder_cache_policy(self) -> None:
        mutations = {
            "job-env.yml": (
                "jobs:\n"
                "  builder:\n"
                "    env:\n"
                "      uses: actions/cache@v6\n"
                "      path: .pio/open-bike-build/downloads\n"
                "    steps:\n"
                "      - run: env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n"
            ),
            "disabled-cache.yml": (
                "jobs:\n"
                "  builder:\n"
                "    steps:\n"
                "      - uses: actions/cache@v6\n"
                "        if: ${{ false }}\n"
                "        with:\n"
                "          path: .pio/open-bike-build/downloads\n"
                "      - run: env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n"
            ),
            "split-cache.yml": (
                "jobs:\n"
                "  builder:\n"
                "    steps:\n"
                "      - uses: actions/cache@v6\n"
                "        with:\n"
                "          path: /tmp/unrelated\n"
                "      - run: env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n"
                "        env:\n"
                "          path: .pio/open-bike-build/downloads\n"
            ),
            "block-scalar.yml": (
                "jobs:\n"
                "  builder:\n"
                "    steps:\n"
                "      - run: |\n"
                "          echo 'uses: actions/cache@v6'\n"
                "          echo 'path: .pio/open-bike-build/downloads'\n"
                "          env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n"
            ),
            "late-cache.yml": (
                "jobs:\n"
                "  builder:\n"
                "    steps:\n"
                "      - run: env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n"
                "      - uses: actions/cache@v6\n"
                "        with:\n"
                "          path: .pio/open-bike-build/downloads\n"
            ),
        }
        for filename, source in mutations.items():
            with self.subTest(filename=filename):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    (root / filename).write_text(source, encoding="utf-8")

                    with self.assertRaises(AssertionError):
                        self.assert_firmware_builders_reuse_verified_downloads(root)

    def test_builder_policy_requires_an_active_exact_run_command(self) -> None:
        mutations = {
            "job-env.yml": (
                "jobs:\n"
                "  builder:\n"
                "    env:\n"
                "      NOTE: env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n"
                "    steps:\n"
                "      - uses: actions/cache@v6\n"
                "        with:\n"
                "          path: .pio/open-bike-build/downloads\n"
            ),
            "echo.yml": (
                "jobs:\n"
                "  builder:\n"
                "    steps:\n"
                "      - run: echo env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n"
            ),
            "disabled.yml": (
                "jobs:\n"
                "  builder:\n"
                "    steps:\n"
                "      - run: env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n"
                "        if: ${{ false }}\n"
            ),
        }
        for filename, source in mutations.items():
            with self.subTest(filename=filename):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    (root / filename).write_text(source, encoding="utf-8")

                    with self.assertRaises(AssertionError):
                        self.assert_firmware_builders_clear_library_overrides(root)

    def test_block_scalar_builder_is_bound_to_its_run_step(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "builder.yml").write_text(
                "jobs:\n"
                "  builder:\n"
                "    steps:\n"
                "      - run: |\n"
                "          env -u LD_LIBRARY_PATH python tools/build_firmware.py TEST\n",
                encoding="utf-8",
            )

            self.assert_firmware_builders_clear_library_overrides(root)

    def test_every_firmware_builder_clears_library_overrides(self) -> None:
        self.assert_firmware_builders_clear_library_overrides()

    def test_every_firmware_builder_reuses_verified_downloads(self) -> None:
        self.assert_firmware_builders_reuse_verified_downloads()


if __name__ == "__main__":
    unittest.main()
