#!/usr/bin/env python3
"""Build and capture one side of the AMOLED artifact-equivalence gate."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path

import build_firmware
from compare_amoled_artifacts import (
    ALLOWED_ENVIRONMENTS,
    EvidenceError,
    REQUIRED_PREPROCESSED_SOURCES,
    _write_json,
    capture,
)
from firmware_runtime import PROVENANCE_ENV
from generated_sdkconfig import current_source_identity


SCHEMA = 1


def _require_regular(path: Path, label: str, *, executable: bool = False) -> Path:
    if path.is_symlink() or not path.is_file():
        raise EvidenceError(f"{label} is missing or unsafe: {path}")
    if executable and not os.access(path, os.X_OK):
        raise EvidenceError(f"{label} is not executable: {path}")
    return path


def _load_manifest(project_dir: Path, environment: str) -> dict[str, object]:
    path = (
        project_dir
        / ".pio/open-bike-build/builds"
        / environment
        / "current.json"
    )
    if path.is_symlink() or not path.is_file():
        raise EvidenceError(f"verified build manifest is missing or unsafe: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"verified build manifest is invalid: {path}") from error
    if not isinstance(value, dict) or value.get("environment") != environment:
        raise EvidenceError("verified build manifest references another environment")
    if value.get("uploadEligible") is not True:
        raise EvidenceError("verified build manifest is not upload-eligible")
    return value


def _run_verified_build(project_dir: Path, environment: str) -> None:
    script = _require_regular(
        project_dir / "tools/build_firmware.py", "firmware build wrapper"
    )
    environment_values = dict(os.environ)
    environment_values.pop("LD_LIBRARY_PATH", None)
    # The qualification driver may use PYTHONPATH to load its preserved tools
    # while the source checkout is on the baseline. It is not a firmware build
    # input and the locked runtime correctly rejects it, so do not inherit it.
    environment_values.pop("PYTHONPATH", None)
    result = subprocess.run(
        [sys.executable, str(script), environment],
        cwd=project_dir,
        env=environment_values,
    )
    if result.returncode != 0:
        raise EvidenceError(
            f"verified firmware build failed for {environment}: {result.returncode}"
        )


def _runtime_environment(
    project_dir: Path, manifest: dict[str, object]
) -> tuple[dict[str, str], Path]:
    provenance = manifest.get("runtimeProvenance")
    if not isinstance(provenance, dict):
        raise EvidenceError("verified build manifest lacks runtime provenance")
    lock_set_id = provenance.get("lockSetId")
    target = provenance.get("target")
    if (
        not isinstance(lock_set_id, str)
        or not lock_set_id
        or Path(lock_set_id).name != lock_set_id
        or lock_set_id in {".", ".."}
    ):
        raise EvidenceError("runtime provenance lacks lockSetId")
    if (
        not isinstance(target, str)
        or not target
        or Path(target).name != target
        or target in {".", ".."}
    ):
        raise EvidenceError("runtime provenance lacks target")
    runtime_root = (
        project_dir / ".pio/open-bike-build/host-runtime" / lock_set_id / target
    )
    pio = _require_regular(runtime_root / "bin/pio", "locked PlatformIO", executable=True)
    uv = _require_regular(runtime_root / "python/bin/uv", "locked uv", executable=True)
    wheelhouse = runtime_root / "wheelhouse"
    if wheelhouse.is_symlink() or not wheelhouse.is_dir():
        raise EvidenceError(f"locked wheelhouse is missing or unsafe: {wheelhouse}")
    esptool_wheels = sorted(wheelhouse.glob("esptool-*.whl"))
    if len(esptool_wheels) != 1:
        raise EvidenceError("locked wheelhouse must contain exactly one esptool wheel")
    pioarduino_requirements = _require_regular(
        runtime_root / "requirements/pioarduino-root.txt",
        "locked pioarduino requirements",
    )
    esp_idf_requirements = _require_regular(
        runtime_root / "requirements/esp-idf.txt", "locked ESP-IDF requirements"
    )
    values = {
        PROVENANCE_ENV: json.dumps(
            provenance, sort_keys=True, separators=(",", ":")
        ),
        "OPEN_BIKE_FIRMWARE_WHEELHOUSE": str(wheelhouse),
        "OPEN_BIKE_FIRMWARE_UV": str(uv),
        "OPEN_BIKE_FIRMWARE_ESPTOOL_WHEEL": str(esptool_wheels[0]),
        "OPEN_BIKE_FIRMWARE_PIOARDUINO_REQUIREMENTS": str(
            pioarduino_requirements
        ),
        "OPEN_BIKE_FIRMWARE_ESP_IDF_REQUIREMENTS": str(esp_idf_requirements),
    }
    return values, pio


def _generate_compilation_database(project_dir: Path, environment: str) -> Path:
    compilation_database = project_dir / "compile_commands.json"
    if compilation_database.exists():
        raise EvidenceError(
            f"refusing to overwrite stale compilation database: {compilation_database}"
        )
    manifest = _load_manifest(project_dir, environment)
    runtime_values, pio = _runtime_environment(project_dir, manifest)
    previous = dict(os.environ)
    try:
        os.environ.update(runtime_values)
        verified_config, platform_archive = (
            build_firmware._verified_platformio_project_config(project_dir)
        )
        identity = current_source_identity(project_dir, environment)
        with build_firmware._project_build_lock(project_dir):
            with build_firmware._deterministic_build_environment(
                project_dir,
                environment,
                identity,
                platform_archive,
                verified_config,
            ):
                result = subprocess.run(
                    [
                        str(pio),
                        "run",
                        "--project-conf",
                        str(verified_config),
                        "-e",
                        environment,
                        "-t",
                        "compiledb",
                    ],
                    cwd=project_dir,
                )
        if result.returncode != 0:
            raise EvidenceError(
                f"deterministic compilation database failed: {result.returncode}"
            )
    finally:
        os.environ.clear()
        os.environ.update(previous)
    return _require_regular(
        compilation_database, "compilation database"
    )


def _load_compilation_commands(path: Path) -> list[dict[str, object]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"compilation database is invalid: {path}") from error
    if not isinstance(value, list) or not value:
        raise EvidenceError("compilation database must be a nonempty JSON array")
    if any(not isinstance(entry, dict) for entry in value):
        raise EvidenceError("compilation database contains a non-object entry")
    return value


def _entry_arguments(entry: dict[str, object]) -> list[str]:
    arguments = entry.get("arguments")
    if isinstance(arguments, list) and all(
        isinstance(argument, str) for argument in arguments
    ):
        return list(arguments)
    command = entry.get("command")
    if isinstance(command, str) and command:
        return shlex.split(command)
    raise EvidenceError("compilation database entry lacks a valid command")


def _source_for_entry(entry: dict[str, object], project_dir: Path) -> str | None:
    filename = entry.get("file")
    directory = entry.get("directory")
    if not isinstance(filename, str) or not isinstance(directory, str):
        raise EvidenceError("compilation database entry lacks file or directory")
    source = Path(filename)
    if not source.is_absolute():
        source = Path(directory) / source
    try:
        return source.resolve().relative_to(project_dir).as_posix()
    except ValueError:
        return None


def _preprocess_arguments(arguments: Sequence[str], source: str, output: Path) -> list[str]:
    if not arguments:
        raise EvidenceError(f"empty compiler command for {source}")
    transformed = [arguments[0]]
    skip_next = False
    found_source = False
    options_with_value = {"-o", "-MF", "-MT", "-MQ"}
    removed_options = {"-c", "-MMD", "-MD", "-MP"}
    for argument in arguments[1:]:
        if skip_next:
            skip_next = False
            continue
        if argument in options_with_value:
            skip_next = True
            continue
        if argument in removed_options:
            continue
        if argument == source or Path(argument).as_posix() == source:
            found_source = True
            continue
        transformed.append(argument)
    if skip_next:
        raise EvidenceError(f"compiler command ends with an incomplete option: {source}")
    if not found_source:
        raise EvidenceError(f"compiler command does not compile its declared source: {source}")
    transformed.extend(("-E", "-P", "-o", str(output), source))
    return transformed


def _preprocess_shared_sources(
    project_dir: Path,
    compilation_database: Path,
    output_dir: Path,
) -> tuple[dict[str, Path], dict[str, object]]:
    output_dir = output_dir.resolve()
    try:
        output_dir.relative_to(project_dir)
    except ValueError:
        pass
    else:
        raise EvidenceError("preprocessing evidence directory must be outside the project")
    if output_dir.exists():
        raise EvidenceError(f"refusing to reuse preprocessing directory: {output_dir}")
    output_dir.mkdir(parents=True)
    entries_by_source: dict[str, dict[str, object]] = {}
    for entry in _load_compilation_commands(compilation_database):
        source = _source_for_entry(entry, project_dir)
        if source in REQUIRED_PREPROCESSED_SOURCES:
            if source in entries_by_source:
                raise EvidenceError(f"duplicate compiler command for {source}")
            entries_by_source[source] = entry
    missing = REQUIRED_PREPROCESSED_SOURCES - set(entries_by_source)
    if missing:
        raise EvidenceError(
            "compilation database lacks shared sources: " + ", ".join(sorted(missing))
        )

    outputs: dict[str, Path] = {}
    commands: dict[str, object] = {}
    for index, source in enumerate(sorted(REQUIRED_PREPROCESSED_SOURCES)):
        entry = entries_by_source[source]
        directory = Path(str(entry["directory"])).resolve()
        try:
            directory.relative_to(project_dir)
        except ValueError as error:
            raise EvidenceError(
                f"compiler working directory escapes the project: {directory}"
            ) from error
        output = output_dir / f"{index}-{Path(source).name}.ii"
        arguments = _preprocess_arguments(_entry_arguments(entry), source, output)
        compiler = Path(arguments[0]).resolve()
        toolchain_root = (
            project_dir / ".pio/open-bike-build/platformio"
        ).resolve()
        try:
            compiler.relative_to(toolchain_root)
        except ValueError as error:
            raise EvidenceError(
                f"compiler is outside the private PlatformIO store: {compiler}"
            ) from error
        _require_regular(compiler, "recorded compiler", executable=True)
        arguments[0] = str(compiler)
        result = subprocess.run(arguments, cwd=directory)
        if result.returncode != 0:
            raise EvidenceError(f"preprocessing failed for {source}: {result.returncode}")
        _require_regular(output, f"preprocessed output for {source}")
        outputs[source] = output
        commands[source] = {
            "directory": str(directory),
            "arguments": arguments,
        }
    return outputs, commands


def qualify(
    *,
    project_dir: Path,
    environment: str,
    preprocessing_dir: Path,
) -> tuple[dict[str, object], dict[str, object]]:
    if environment not in ALLOWED_ENVIRONMENTS:
        raise EvidenceError(f"unsupported AMOLED equivalence environment: {environment}")
    project_dir = project_dir.resolve()
    _run_verified_build(project_dir, environment)
    compilation_database = _generate_compilation_database(project_dir, environment)
    preprocessed, commands = _preprocess_shared_sources(
        project_dir, compilation_database, preprocessing_dir.resolve()
    )
    compilation_database.unlink()

    # The compilation-database target runs PlatformIO's package setup. Rebuild
    # through the wrapper so the evidence always refers to a fresh final
    # attestation, never to state potentially changed by that introspection.
    _run_verified_build(project_dir, environment)
    evidence = capture(
        project_dir=project_dir,
        environment=environment,
        preprocessed=preprocessed,
    )
    command_record: dict[str, object] = {
        "schema": SCHEMA,
        "environment": environment,
        "sourceIdentity": evidence["sourceIdentity"],
        "commands": commands,
    }
    return evidence, command_record


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, required=True)
    parser.add_argument(
        "--environment", choices=sorted(ALLOWED_ENVIRONMENTS), required=True
    )
    parser.add_argument("--preprocessing-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--commands-output", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        evidence, commands = qualify(
            project_dir=args.project_dir,
            environment=args.environment,
            preprocessing_dir=args.preprocessing_dir,
        )
        _write_json(args.output, evidence)
        _write_json(args.commands_output, commands)
        print(
            "AMOLED_EQUIVALENCE_QUALIFICATION "
            f"environment={evidence['environment']} "
            f"git={evidence['sourceIdentity']} "
            f"objects={len(evidence['objectsSha256'])} "
            f"preprocessed={len(evidence['preprocessedSha256'])}"
        )
        return 0
    except (EvidenceError, OSError) as error:
        print(f"AMOLED equivalence qualification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
