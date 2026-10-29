#!/usr/bin/env python3
"""Classify changed paths into the minimum safe GitHub Actions CI jobs."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from collections.abc import Iterable, Sequence


sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_scopes

COMPONENTS = ("firmware_build", "firmware_host", "ios", "map_backend", "osm")
FIRMWARE_TARGETS = {
    "397": (
        "WAVESHARE_EPAPER_397",
        "WAVESHARE_EPAPER_397_DISPLAY_TEST",
        "WAVESHARE_EPAPER_397_POWER_METRICS",
        "WAVESHARE_EPAPER_397_IMU_DIAGNOSTICS",
        "WAVESHARE_EPAPER_397_LIGHT_SLEEP",
        "WAVESHARE_EPAPER_397_PRODUCTION",
    ),
    "175": (
        "WAVESHARE_AMOLED_175",
        "WAVESHARE_AMOLED_175_REMOTE_DEBUG",
        "WAVESHARE_AMOLED_175_PRODUCTION",
        "WAVESHARE_AMOLED_175_LIFECYCLE_QUALIFICATION",
        "WAVESHARE_AMOLED_175_POI_LIFECYCLE_QUALIFICATION",
    ),
    "206": (
        "WAVESHARE_AMOLED_206",
        "WAVESHARE_AMOLED_206_REMOTE_DEBUG",
        "WAVESHARE_AMOLED_206_PRODUCTION",
        "WAVESHARE_AMOLED_206_LIFECYCLE_QUALIFICATION",
        "WAVESHARE_AMOLED_206_POI_LIFECYCLE_QUALIFICATION",
    ),
}
FULL_CI_PATHS = {
    ".github/scripts/changed_components.py",
    ".github/scripts/ci_scopes.py",
    ".github/workflows/ci.yml",
}
FIRMWARE_HOST_ONLY_PATH_PREFIXES = ("esp32/tools/tests/",)
# This host renderer runs after a firmware build supplies pinned LVGL sources.
FIRMWARE_RENDER_TEST_PATHS = {
    "esp32/tools/tests/test_social_riders_render.cpp",
    "esp32/tools/run_social_riders_render_test.py",
    "tools/generate_ride_stats_preview.py",
    "tools/ride_stats_preview/lvgl-source.lock.json",
}
FIRMWARE_HOST_PATH_PREFIXES = (
    ".github/actions/firmware-build-cache/",
    ".github/actions/require-immutable-releases/",
    ".github/actions/require-firmware-release-controls/",
)
FIRMWARE_WORKFLOW_PATHS = {
    ".github/workflows/firmware-diagnostics.yml",
    ".github/scripts/diagnostic_changes.py",
    ".github/workflows/workout-zone-contracts.yml",
    ".github/workflows/firmware-cache-qualification.yml",
    ".github/workflows/firmware-core-warm.yml",
    ".github/workflows/firmware-release-candidate.yml",
    ".github/workflows/firmware-release.yml",
    ".github/workflows/firmware-runtime-performance.yml",
    ".github/workflows/firmware-runtime-publish.yml",
    ".github/workflows/firmware-runtime-refresh.yml",
    ".github/workflows/speaker-firmware.yml",
}
MAP_WORKFLOW_PATHS = {
    ".github/workflows/map-platform-ci.yml",
    ".github/scripts/dispatch_promotion_ci.py",
    ".github/workflows/map-platform-image.yml",
}
# Native POI equivalence imports the backend shard producer/selector. Keep its
# product-container gate active even when no extractor file changes.
OSM_BACKEND_PATHS = {
    "map-platform/backend/map_platform/__init__.py",
    "map-platform/backend/map_platform/source_shards.py",
    "map-platform/backend/tests/test_source_shards.py",
}
FIRMWARE_CONTRACT_PATHS = {
    "docs/device-ownership-test-vectors.json",
    "docs/firmware-battery-life-hardware-validation.md",
    "docs/firmware-build-provenance.md",
    "docs/firmware-factory-release.md",
    "docs/firmware-map-memory-diagnostics.md",
    "docs/firmware-map-render-scheduler.md",
    "docs/firmware-map-rendering-psram.md",
    "docs/firmware-runtime-maintenance.md",
}
FIRMWARE_MANIFEST_PATHS = {
    "tools/firmware_manifest.py",
    "tools/tests/test_firmware_manifest.py",
    # Host contract tests pin its slot sizes and pre-write ordering.
    "ios-app/BikeComputer/BikeComputer/Managers/FirmwareUpdateManager.swift",
}
RIDE_DIAGNOSTICS_TOOL_PATHS = {"tools/ride_diagnostics.py", "tools/bicino"}
SHARED_RIDE_BLE_CONTRACT_PATHS = {
    "protocol/ride-ble-contract-v1.json",
    "tools/generate_ride_ble_contract.py",
    "protocol/diagnostics/registry-v2.json",
    "tools/generate_diagnostics_contract.py",
}
FIRMWARE_RELEASE_TOOL_PATHS = {
    ".github/firmware-release-authority.json",
    ".github/scripts/firmware_key_migration.py",
    ".github/scripts/firmware_release_controls.py",
    ".github/workflows/firmware-key-migration.yml",
    ".github/scripts/firmware_release_gate.py",
    "tools/factory_release_manifest.py",
    "tools/firmware_release_candidate.py",
    "tools/firmware-signing-requirements.txt",
    "tools/verify_github_release_assets.py",
    "tools/web_flasher_manifest.py",
}
# Signed USB recovery/migration/identity vectors; the website copies them byte-for-byte.
FIRMWARE_WEB_FLASHER_PREFIX = "tools/web-flasher/"
IOS_CONTRACT_PATHS = {
    "docs/app-store-privacy-disclosures.md",
    "docs/device-ownership-test-vectors.json",
    "docs/releases/watchos-workout-companion.md",
}
SHARED_FMB_FIXTURE_PREFIX = "tools/tests/fixtures/fmb/"
SHARED_MAP_STREAM_FIXTURE_PATH = (
    "map-platform/backend/tests/fixtures/map_stream_v1_golden.txt"
)
SHARED_CONTOUR_COMPANION_FIXTURE_PATH = (
    "map-platform/backend/tests/fixtures/map_contour_companion_v1.txt"
)
# Durable map contract inputs and their readers. Every map-platform/ path also
# selects the backend (and so the catalog Worker) below.
SHARED_MAP_COMPATIBILITY_CORPUS_PREFIX = (
    "map-platform/backend/tests/fixtures/map-compatibility-v"
)
SHARED_MAP_COMPATIBILITY_CONTRACT_PREFIX = "map-platform/config/map-compatibility-contract-v"
SHARED_MAP_READER_CAPABILITY_FIXTURE_PREFIX = "protocol/fixtures/map-reader-capabilities-v"
# Client map-stream trust. The backend checks that these still match the trust
# registry and keep every durable map signer trusted.
MAP_STREAM_CLIENT_TRUST_PATHS = {
    "esp32/lib/map_transfer/map_stream_compiled_keys.generated.inc",
    "esp32/lib/map_transfer/map_stream_development_compiled_key.generated.inc",
    "ios-app/BikeComputer/BikeComputer/Models/BikeMapStreamProductionTrust.generated.swift",
    "ios-app/BikeComputer/Configuration/Development.xcconfig",
}
SHARED_ROUTE_ELEVATION_FIXTURE_PATHS = (
    "protocol/fixtures/route-elevation-v1/",
    "tools/generate_route_elevation_fixtures.py",
)
SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
ZERO_SHA = "0" * 40

CHECK_REGISTRY = "tools/development/checks.json"
IOS_FAST_ONLY_PATHS = {
    "tools/development/swift-sources.json", "tools/development/swift_compile.py",
    "tools/replay_scenario.py", "ios-app/tests/scenario-replay/main.swift",
    "ios-app/scripts/run-cycling-sensor-observation-tests.sh",
}
IOS_FAST_ONLY_PREFIXES = ("protocol/scenarios/", "ios-app/scripts/tests/", "ios-app/tests/scenario-replay/")


def registry_affected_components(before, after):
    """Scope recipe edits to their old and new consumers; unknown metadata is global."""
    try:
        old, new = json.loads(before), json.loads(after)
        if {k:v for k,v in old.items() if k != "checks"} != {k:v for k,v in new.items() if k != "checks"}:
            return None
        def indexed(value):
            checks = {c["id"]: c for c in value["checks"]}
            if len(checks) != len(value["checks"]): raise ValueError("duplicate check")
            if any(c["component"] not in {*COMPONENTS, "ios_native", "development"} for c in checks.values()):
                raise ValueError("unknown consumer")
            return checks
        old_checks, new_checks = indexed(old), indexed(new)
        result = set()
        for identifier in old_checks.keys() | new_checks.keys():
            if old_checks.get(identifier) != new_checks.get(identifier):
                result.update(c["component"] for c in (old_checks.get(identifier), new_checks.get(identifier)) if c)
        return result
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def registry_changed_components(base, head=None):
    try:
        before = subprocess.check_output(["git", "show", f"{base}:{CHECK_REGISTRY}"],stderr=subprocess.DEVNULL)
        after = (subprocess.check_output(["git", "show", f"{head}:{CHECK_REGISTRY}"],stderr=subprocess.DEVNULL) if head
                 else (Path(__file__).resolve().parents[2] / CHECK_REGISTRY).read_bytes())
        return registry_affected_components(before, after)
    except (OSError, subprocess.SubprocessError):
        return None


def native_ios_required(paths, *, run_all=False, registry_components=None):
    native_paths = [p for p in paths if p not in IOS_FAST_ONLY_PATHS and p not in ci_scopes.SHARED_FAST_CHECKS and not p.startswith(IOS_FAST_ONLY_PREFIXES)
                    and not (p == CHECK_REGISTRY and registry_components is not None and "ios_native" not in registry_components)]
    return classify_paths(native_paths, run_all=run_all, registry_components=registry_components)["ios"]


def classify_paths(paths: Iterable[str], *, run_all: bool = False, registry_components=None) -> dict[str, bool]:
    """Return the CI components affected by a collection of Git paths."""

    paths = tuple(paths)
    selected = _classify_known_paths(paths, run_all=run_all, registry_components=registry_components)
    if not run_all:
        for path in paths:
            # Stop before expensive jobs when ownership is unknown. An explicit
            # consumer mapping is required; neither a green skip nor full CI is
            # a substitute for that decision.
            if (path.startswith(("tools/", "protocol/", ".github/"))
                    and not path.endswith(".md") and path != CHECK_REGISTRY
                    and not path.startswith(("tools/development/tests/", ".github/scripts/tests/"))
                    and not any(_classify_known_paths([path], registry_components=registry_components).values())):
                raise ValueError(f'unclassified CI input: {path}; add an explicit consumer mapping')
    return selected


def _classify_known_paths(paths: Iterable[str], *, run_all=False, registry_components=None) -> dict[str, bool]:
    selected = {component: run_all for component in COMPONENTS}
    if run_all:
        return selected

    for raw_path in paths:
        path = raw_path
        if not path:
            continue

        if path in ci_scopes.SHARED_FAST_CHECKS:
            checks = {c['id']: c for c in ci_scopes.registry_checks()}
            for identifier in ci_scopes.SHARED_FAST_CHECKS[path]:
                if identifier not in checks:
                    raise ValueError(f'unknown shared-input check: {identifier}')
                selected[checks[identifier]['component']] = True
            continue

        # Runner/environment entry points route like their tools/development/ code.
        if path in FULL_CI_PATHS or path in {"tools/dev-check", "tools/dev_check.py", "tools/dev-setup", "tools/dev-env"}:
            return {component: True for component in COMPONENTS}

        if path == CHECK_REGISTRY:
            if registry_components is None:
                return {component: True for component in COMPONENTS}
            for component in registry_components:
                if component == "ios_native": component = "ios"
                if component in selected: selected[component] = True
        elif path in IOS_FAST_ONLY_PATHS or path in {"tools/development/simulator_session.py", "tools/development/ios_build.py"}:
            selected["ios"] = True
        elif path == "tools/development/requirements.txt":
            selected["firmware_host"] = True
        elif path.startswith("tools/development/") and not path.startswith("tools/development/tests/"):
            return {component: True for component in COMPONENTS}

        if (path.startswith(".github/actions/firmware-build-cache/")
                or path == ".github/scripts/firmware_core_artifact.py"):
            # Every firmware build restores through these; host tests cover their unit tests.
            selected["firmware_build"] = True
            selected["firmware_host"] = True

        if path.startswith("esp32/"):
            selected["firmware_host"] = True
            if (
                not path.startswith(FIRMWARE_HOST_ONLY_PATH_PREFIXES)
                and not path.endswith(".md")
            ):
                selected["firmware_build"] = True

        if path in FIRMWARE_RENDER_TEST_PATHS or path.startswith('tools/ride_stats_preview/'):
            selected["firmware_build"] = True
            selected["firmware_host"] = True

        if (
            path.startswith("tools/tests/")
            or path.startswith(FIRMWARE_HOST_PATH_PREFIXES)
            or path in FIRMWARE_WORKFLOW_PATHS
            or path in FIRMWARE_CONTRACT_PATHS
            or path in FIRMWARE_RELEASE_TOOL_PATHS
            or path in RIDE_DIAGNOSTICS_TOOL_PATHS
            or path.startswith("tools/bicino_diagnostics/")
            or path.startswith(FIRMWARE_WEB_FLASHER_PREFIX)
        ):
            selected["firmware_host"] = True

        if path in {"tools/build_evidence.py", "tools/build-and-record-firmware"}:
            # Both native build jobs exercise evidence collection and retention.
            selected["firmware_build"] = True
            selected["firmware_host"] = True
            if path == "tools/build_evidence.py": selected["ios"] = True
        if path == "tools/incident_bundle.py":
            selected["firmware_host"] = True
        if path.startswith("protocol/scenarios/") or path == "tools/replay_scenario.py":
            selected["firmware_host"] = True
            selected["ios"] = True

        if path.startswith("ios-app/") or path in IOS_CONTRACT_PATHS:
            selected["ios"] = True

        if path in FIRMWARE_MANIFEST_PATHS:
            # The release producer and the shipped iOS verifier share this contract.
            selected["firmware_host"] = True
            selected["ios"] = True

        if path in SHARED_RIDE_BLE_CONTRACT_PATHS:
            selected["firmware_build"] = True
            selected["firmware_host"] = True
            selected["ios"] = True

        if path == ".dockerignore" or path.startswith("map-platform/"):
            selected["map_backend"] = True

        if path in OSM_BACKEND_PATHS:
            selected["osm"] = True

        if path.startswith("tools/OSM_Extract/"):
            # The production backend image copies the extractor into its image.
            selected["map_backend"] = True
            selected["osm"] = True

        if path.startswith(SHARED_FMB_FIXTURE_PREFIX):
            # Firmware, the backend, and the extractor all assert these bytes.
            selected["firmware_host"] = True
            selected["map_backend"] = True
            selected["osm"] = True

        if path == SHARED_MAP_STREAM_FIXTURE_PATH:
            # The same signed-stream bytes are parsed by backend, iOS, and firmware.
            selected["firmware_host"] = True
            selected["ios"] = True
            selected["map_backend"] = True

        if path == SHARED_CONTOUR_COMPANION_FIXTURE_PATH:
            # Backend-produced signed maps and companions drive the iPhone
            # delivery contract tests.
            selected["ios"] = True
            selected["map_backend"] = True

        if path.startswith(SHARED_MAP_COMPATIBILITY_CORPUS_PREFIX):
            # The frozen producer corpus is read by the backend, catalog,
            # iPhone and firmware compatibility tests.
            selected["firmware_host"] = True
            selected["ios"] = True
        if path.startswith(SHARED_MAP_COMPATIBILITY_CONTRACT_PREFIX):
            # The worker and the iPhone reader test both load the contract.
            selected["ios"] = True
        if path.startswith(SHARED_MAP_READER_CAPABILITY_FIXTURE_PREFIX):
            # Firmware must report these bytes; the iPhone decodes them.
            selected["firmware_host"] = True
            selected["ios"] = True
        if path in MAP_STREAM_CLIENT_TRUST_PATHS:
            selected["map_backend"] = True

        if path.startswith(SHARED_ROUTE_ELEVATION_FIXTURE_PATHS):
            # Backend processing, the Swift codec and the firmware decoder all
            # assert the same route elevation fixtures.
            selected["firmware_host"] = True
            selected["ios"] = True
            selected["map_backend"] = True

        if path in MAP_WORKFLOW_PATHS:
            selected["map_backend"] = True
            selected["osm"] = True

    return selected


def select_scope(scope: str) -> dict[str, bool] | None:
    """Return an explicit workflow-dispatch selection, or None for path routing."""

    if scope == "auto":
        return None
    if scope == "all":
        return {component: True for component in COMPONENTS}
    if scope == "firmware":
        return {
            "firmware_build": True,
            "firmware_host": True,
            "ios": False,
            "map_backend": False,
            "osm": False,
        }
    if scope == "ios":
        return {
            "firmware_build": False,
            "firmware_host": False,
            "ios": True,
            "map_backend": False,
            "osm": False,
        }
    if scope == "map":
        return {
            "firmware_build": False,
            "firmware_host": False,
            "ios": False,
            "map_backend": True,
            "osm": True,
        }
    raise ValueError(f"unsupported CI scope: {scope}")


def select_firmware_targets(hardware: str) -> tuple[str, ...]:
    """Return the explicitly selected firmware build environments."""

    if hardware == "all":
        return FIRMWARE_TARGETS["175"] + FIRMWARE_TARGETS["206"]
    try:
        return FIRMWARE_TARGETS[hardware]
    except KeyError as error:
        raise ValueError(f"unsupported firmware hardware: {hardware}") from error


def _validated_sha(value: str, label: str) -> str:
    if not SHA_PATTERN.fullmatch(value):
        raise ValueError(f"{label} must be a 40-character Git SHA")
    return value.lower()


def git_diff_command(event: str, base: str, head: str) -> Sequence[str] | None:
    """Build the Git command that lists paths changed by a workflow event."""

    if event == "workflow_dispatch":
        return None

    head_sha = _validated_sha(head, "head")
    base_sha = _validated_sha(base, "base")
    if event == "pull_request":
        return (
            "git",
            "diff",
            "--no-renames",
            "--name-only",
            "-z",
            f"{base_sha}...{head_sha}",
            "--",
        )
    if event == "merge_group":
        return (
            "git",
            "diff",
            "--no-renames",
            "--name-only",
            "-z",
            f"{base_sha}..{head_sha}",
            "--",
        )
    if event == "push":
        if base_sha == ZERO_SHA:
            return (
                "git",
                "diff-tree",
                "--no-renames",
                "--root",
                "--no-commit-id",
                "--name-only",
                "-r",
                "-z",
                head_sha,
                "--",
            )
        return (
            "git",
            "diff",
            "--no-renames",
            "--name-only",
            "-z",
            f"{base_sha}..{head_sha}",
            "--",
        )
    raise ValueError(f"unsupported GitHub event: {event}")


def changed_paths(event: str, base: str, head: str) -> tuple[str, ...] | None:
    """Read the changed paths for an event, or return None for a full manual run."""

    command = git_diff_command(event, base, head)
    if command is None:
        return None
    result = subprocess.run(command, check=True, capture_output=True)
    return tuple(
        entry.decode("utf-8", errors="surrogateescape")
        for entry in result.stdout.split(b"\0")
        if entry
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default=ZERO_SHA)
    parser.add_argument("--head", default=ZERO_SHA)
    parser.add_argument(
        "--scope",
        choices=("auto", "all", "firmware", "ios", "map"),
        default="auto",
    )
    parser.add_argument(
        "--firmware-hardware",
        choices=("175", "206", "397", "all"),
        default="175",
    )
    args = parser.parse_args()

    try:
        paths = None
        selected = select_scope(args.scope)
        native_ios = selected["ios"] if selected is not None else False
        if selected is None:
            paths = changed_paths(args.event, args.base, args.head)
            affected = registry_changed_components(args.base, args.head) if paths and CHECK_REGISTRY in paths else None
            selected = classify_paths(paths or (), run_all=not paths, registry_components=affected)
            native_ios = native_ios_required(paths or (), run_all=not paths, registry_components=affected)
    except (subprocess.CalledProcessError, ValueError) as error:
        parser.error(str(error))

    for component in COMPONENTS:
        value = "true" if selected[component] else "false"
        print(f"{component}={value}")
    firmware_targets = json.dumps(
        ci_scopes.firmware_targets(paths, select_firmware_targets(args.firmware_hardware)),
        separators=(",", ":"),
    )
    print(f"firmware_targets={firmware_targets}")
    print(f"ios_native={'true' if native_ios else 'false'}")
    details = {**ci_scopes.map_scopes(paths, selected=selected["map_backend"]),
               **ci_scopes.ios_scopes(paths, native=native_ios, selected=selected["ios"]),
               'firmware_host_checks': ci_scopes.firmware_host_checks(paths, selected=selected['firmware_host']),
               'firmware_renderer': ci_scopes.firmware_renderer_required(paths),
               'zone_contracts': ci_scopes.zone_contracts_required(paths, ios=selected['ios'], firmware_host=selected['firmware_host'])}
    for key, value in details.items():
        print(f"{key}={json.dumps(value, separators=(',', ':'))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
