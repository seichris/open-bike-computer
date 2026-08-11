#!/usr/bin/env python3
"""Build and assemble reviewed, offline firmware-runtime candidates."""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import gzip
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
import urllib.parse
import zipfile
from email.parser import BytesParser
from pathlib import Path, PurePosixPath
from typing import Mapping, Sequence

from firmware_runtime import (
    Artifact,
    FirmwareRuntimeError,
    _duplicate_key_rejector,
    _verify_runtime_tree,
    extract_verified_bundle,
    load_lock,
    select_target,
)
from generated_sdkconfig import (
    WAVESHARE_PLATFORM_ARCHIVE_SHA256,
    WAVESHARE_PLATFORM_PACKAGES_SHA256,
)


GROUP_NAMES = ("topLevel", "pioarduinoRoot", "espIdf", "uv", "esptool")
LICENSE_REPORT_SCHEMA = 2
COMMAND_ENVIRONMENT_KEYS = {"HOME", "TMPDIR", "UV_CACHE_DIR", "XDG_CACHE_HOME"}
GROUP_LABELS = {
    "topLevel": "top-level",
    "pioarduinoRoot": "pioarduino-root",
    "espIdf": "esp-idf",
    "uv": "uv",
    "esptool": "esptool",
}
REQUIREMENT_FILENAMES = {
    "topLevel": "top-level.txt",
    "pioarduinoRoot": "pioarduino-root.txt",
    "espIdf": "esp-idf.txt",
    "uv": "uv.txt",
    "esptool": "esptool.txt",
}


def _canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _download_artifact(
    artifact: Artifact, output: Path, *, environment: Mapping[str, str] | None = None
) -> None:
    if output.exists() or output.is_symlink():
        raise FirmwareRuntimeError(f"runtime refresh output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    _run(
        (
            "/usr/bin/curl",
            "--disable",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--output",
            str(output),
            artifact.url,
        ),
        environment=environment,
    )
    if output.stat().st_size != artifact.size or _sha256(output) != artifact.sha256:
        raise FirmwareRuntimeError(f"downloaded refresh artifact failed verification: {artifact.url}")


def _normalize_name(value: str) -> str:
    result = "".join("-" if character in "_.-" else character.lower() for character in value)
    while "--" in result:
        result = result.replace("--", "-")
    return result.strip("-")


def _load_inputs(
    project_dir: Path,
) -> tuple[
    dict[str, object],
    dict[tuple[str, str], dict[str, object]],
    Path,
    Path,
]:
    runtime_dir = project_dir / "tools/firmware-runtime"
    refresh = runtime_dir / "refresh-inputs.json"
    licenses = runtime_dir / "licenses.json"
    for path in (refresh, licenses):
        if path.is_symlink() or not path.is_file():
            raise FirmwareRuntimeError(f"runtime refresh input is missing or unsafe: {path}")
    try:
        value = json.loads(
            refresh.read_bytes(), object_pairs_hook=_duplicate_key_rejector
        )
        licenses_value = json.loads(
            licenses.read_bytes(), object_pairs_hook=_duplicate_key_rejector
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise FirmwareRuntimeError(
            f"could not parse runtime refresh metadata: {error}"
        ) from error
    if not isinstance(value, dict) or value.get("schema") != 2:
        raise FirmwareRuntimeError("runtime refresh inputs must use schema 2")
    expected_fields = {
        "schema", "distributionSets", "platformio", "pythonBuilder",
        "pythonStandaloneRelease", "pythonSource", "pythonVersion", "sources",
        "targets", "uv",
    }
    if set(value) != expected_fields:
        raise FirmwareRuntimeError(
            "runtime refresh inputs have missing or unexpected fields"
        )
    sets = value.get("distributionSets")
    sources = value.get("sources")
    if not isinstance(sets, dict) or set(sets) != set(GROUP_NAMES) or not isinstance(sources, dict):
        raise FirmwareRuntimeError("runtime refresh distribution inputs are incomplete")
    for name in GROUP_NAMES:
        requirements = sets[name]
        if (
            not isinstance(requirements, list)
            or not requirements
            or len(requirements) != len(set(requirements))
            or not all(
                isinstance(item, str)
                and re.fullmatch(
                    r"[A-Za-z0-9][A-Za-z0-9_.-]*==[^<>=~,*\s]+", item
                )
                for item in requirements
            )
        ):
            raise FirmwareRuntimeError(f"runtime refresh set {name} is not exact and canonical")
    if (
        not isinstance(value["platformio"], str)
        or f"platformio=={value['platformio']}" not in sets["topLevel"]
        or not isinstance(value["uv"], str)
        or f"uv=={value['uv']}" not in sets["uv"]
        or value["pythonVersion"] != "3.13.15"
        or not isinstance(value["pythonStandaloneRelease"], str)
        or re.fullmatch(r"[0-9]{8}", value["pythonStandaloneRelease"]) is None
        or value["targets"]
        != ["linux-x86_64-cp313", "macos-arm64-cp313"]
    ):
        raise FirmwareRuntimeError("runtime refresh versions or targets are invalid")
    if (
        not isinstance(sources, dict)
        or set(sources) != {"pioarduino-core", "esptool"}
    ):
        raise FirmwareRuntimeError("runtime refresh sources are incomplete")
    for source_name, source in sources.items():
        if not isinstance(source, dict) or set(source) != {"url", "size", "sha256"}:
            raise FirmwareRuntimeError(f"runtime refresh source {source_name} is invalid")
        _validate_input_artifact(source, f"runtime refresh source {source_name}")
    python_source = value["pythonSource"]
    if (
        not isinstance(python_source, dict)
        or set(python_source) != {"url", "size", "sha256", "license"}
        or python_source.get("license") != "Python-2.0"
    ):
        raise FirmwareRuntimeError("CPython source provenance is incomplete")
    source_artifact = _validate_input_artifact(
        python_source, "CPython source artifact", allow_license=True
    )
    if not source_artifact.url.startswith("https://www.python.org/ftp/python/"):
        raise FirmwareRuntimeError("CPython source artifact is invalid")
    python_builder = value["pythonBuilder"]
    if (
        not isinstance(python_builder, dict)
        or set(python_builder) != {"url", "commit"}
        or python_builder.get("url")
        != "https://github.com/astral-sh/python-build-standalone"
        or not isinstance(python_builder.get("commit"), str)
        or len(python_builder["commit"]) != 40
        or any(character not in "0123456789abcdef" for character in python_builder["commit"])
    ):
        raise FirmwareRuntimeError("CPython builder provenance is invalid")
    if (
        not isinstance(licenses_value, dict)
        or set(licenses_value) != {"schema", "components", "wheelOverrides"}
        or licenses_value.get("schema") != 2
        or not isinstance(licenses_value.get("components"), list)
        or not licenses_value["components"]
        or not isinstance(licenses_value.get("wheelOverrides"), list)
        or licenses.read_bytes() != _canonical(licenses_value)
    ):
        raise FirmwareRuntimeError("runtime license inventory is invalid")
    component_names: set[str] = set()
    for component in licenses_value["components"]:
        if (
            not isinstance(component, dict)
            or set(component) != {"name", "license", "source"}
            or not all(
                isinstance(component[key], str) and component[key]
                for key in ("name", "license", "source")
            )
            or not component["source"].startswith("https://")
            or component["name"] in component_names
        ):
            raise FirmwareRuntimeError("runtime license inventory component is invalid")
        component_names.add(component["name"])
    if {"CPython", "python-build-standalone", "uv", "PlatformIO Core"} - component_names:
        raise FirmwareRuntimeError("runtime license inventory is incomplete")
    wheel_overrides: dict[tuple[str, str], dict[str, object]] = {}
    for override in licenses_value["wheelOverrides"]:
        if (
            not isinstance(override, dict)
            or set(override) != {"name", "version", "license", "evidenceFiles"}
            or not isinstance(override.get("name"), str)
            or not override["name"]
            or override["name"] != _normalize_name(override["name"])
            or not isinstance(override.get("version"), str)
            or re.fullmatch(r"[^<>=~,*\s]+", override["version"]) is None
            or not isinstance(override.get("license"), str)
            or override["license"].casefold() in {"unknown", "unlicensed"}
            or re.fullmatch(
                r"[A-Za-z0-9][A-Za-z0-9.+-]*(?: (?:AND|OR|WITH) [A-Za-z0-9][A-Za-z0-9.+-]*)*",
                override["license"],
            )
            is None
            or not isinstance(override.get("evidenceFiles"), list)
            or not override["evidenceFiles"]
            or not all(
                isinstance(name, str) for name in override["evidenceFiles"]
            )
            or len(override["evidenceFiles"]) != len(set(override["evidenceFiles"]))
        ):
            raise FirmwareRuntimeError("runtime wheel license override is invalid")
        for name in override["evidenceFiles"]:
            if (
                not name
                or re.fullmatch(r"[A-Za-z0-9_.+/-]+", name) is None
                or PurePosixPath(name).is_absolute()
                or any(part in {"", ".", ".."} for part in PurePosixPath(name).parts)
                or str(PurePosixPath(name)) != name
            ):
                raise FirmwareRuntimeError(
                    "runtime wheel license evidence path is invalid"
                )
        key = (override["name"], override["version"])
        if key in wheel_overrides:
            raise FirmwareRuntimeError("runtime wheel license override is duplicated")
        wheel_overrides[key] = override
    return value, wheel_overrides, refresh, licenses


def _validate_input_artifact(
    value: Mapping[str, object], label: str, *, allow_license: bool = False
) -> Artifact:
    expected = {"url", "size", "sha256"} | ({"license"} if allow_license else set())
    if set(value) != expected:
        raise FirmwareRuntimeError(f"{label} has missing or unexpected fields")
    artifact = Artifact(value["url"], value["size"], value["sha256"])
    if (
        not isinstance(artifact.url, str)
        or not artifact.url.startswith("https://")
        or not isinstance(artifact.size, int)
        or isinstance(artifact.size, bool)
        or artifact.size <= 0
        or not isinstance(artifact.sha256, str)
        or re.fullmatch(r"[0-9a-f]{64}", artifact.sha256) is None
    ):
        raise FirmwareRuntimeError(f"{label} is invalid")
    return artifact


def inspect_inputs(project_dir: Path) -> dict[str, object]:
    value, wheel_license_overrides, refresh, licenses = _load_inputs(project_dir)
    lock = load_lock(project_dir / "tools/firmware-runtime/lock-v1.json")
    for target in lock.targets:
        _require_matching_python_provenance(value, target)
    return {
        "schema": 2,
        "lockSetId": lock.lock_set_id,
        "lockManifestSha256": lock.manifest_sha256,
        "refreshInputsSha256": _sha256(refresh),
        "licensesSha256": _sha256(licenses),
        "targets": [{"id": target.target_id, "accepted": target.accepted} for target in lock.targets],
        "distributionCounts": {name: len(value["distributionSets"][name]) for name in GROUP_NAMES},
        "wheelLicenseOverrideCount": len(wheel_license_overrides),
    }


def _require_matching_python_provenance(
    inputs: Mapping[str, object], target: object
) -> Artifact:
    source_value = inputs["pythonSource"]
    expected_source = Artifact(
        source_value["url"], source_value["size"], source_value["sha256"]
    )
    builder_value = inputs["pythonBuilder"]
    if (
        target.python.license != source_value["license"]
        or target.python.source != expected_source
        or target.python.builder.url != builder_value["url"]
        or target.python.builder.commit != builder_value["commit"]
    ):
        raise FirmwareRuntimeError(
            f"runtime target {target.target_id} CPython provenance disagrees with refresh inputs"
        )
    return expected_source


def verify_python_input(project_dir: Path, target_id: str, output: Path) -> dict[str, object]:
    inputs, _, _, _ = _load_inputs(project_dir)
    lock = load_lock(project_dir / "tools/firmware-runtime/lock-v1.json")
    matches = [target for target in lock.targets if target.target_id == target_id]
    if len(matches) != 1:
        raise FirmwareRuntimeError(f"unknown runtime refresh target: {target_id}")
    target = matches[0]
    _require_matching_python_provenance(inputs, target)
    _download_artifact(target.python, output)
    return {
        "schema": 1,
        "target": target.target_id,
        "pythonVersion": target.python_version,
        "size": output.stat().st_size,
        "sha256": _sha256(output),
        "sourceUrl": target.python.url,
    }


def _extract_python(archive_path: Path, destination: Path) -> Path:
    extracted = destination.parent / ".python-extracted"
    extracted.mkdir(mode=0o700)
    with tarfile.open(archive_path, "r:gz") as archive:
        archive.extractall(extracted, filter="data")
    source = extracted / "python"
    if source.is_symlink() or not source.is_dir():
        raise FirmwareRuntimeError("standalone Python archive has no safe python root")
    root = extracted.resolve()
    for path in extracted.rglob("*"):
        if path.is_symlink():
            try:
                path.resolve(strict=True).relative_to(root)
            except (OSError, ValueError) as error:
                raise FirmwareRuntimeError("standalone Python contains an escaping link") from error
        elif not path.is_file() and not path.is_dir():
            raise FirmwareRuntimeError("standalone Python contains a special file")
    shutil.copytree(source, destination, symlinks=False)
    shutil.rmtree(extracted)
    python = destination / "bin/python3"
    if python.is_symlink() or not python.is_file() or not os.access(python, os.X_OK):
        raise FirmwareRuntimeError("standalone Python executable is missing")
    return python


def _run(
    command: Sequence[str],
    *,
    cwd: Path | None = None,
    environment: Mapping[str, str] | None = None,
) -> str:
    subprocess_environment = {
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "HOME": "/nonexistent/open-bike-firmware-runtime",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "PIP_CONFIG_FILE": os.devnull,
        "PIP_DISABLE_PIP_VERSION_CHECK": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONHASHSEED": "0",
        "PYTHONNOUSERSITE": "1",
        "SOURCE_DATE_EPOCH": "0",
        "UV_NO_CONFIG": "1",
    }
    if environment:
        unexpected = set(environment) - COMMAND_ENVIRONMENT_KEYS
        if unexpected:
            raise FirmwareRuntimeError(
                "candidate command environment contains unsupported names: "
                + ", ".join(sorted(unexpected))
            )
        subprocess_environment.update(environment)
    result = subprocess.run(
        command,
        cwd=cwd,
        env=subprocess_environment,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise FirmwareRuntimeError(
            f"candidate command failed ({result.returncode}): {' '.join(command)}\n{result.stdout}\n{result.stderr}"
        )
    return result.stdout.strip()


def _isolated_command_environment(root: Path) -> dict[str, str]:
    home = root / "home"
    temporary = root / "tmp"
    cache = root / "cache"
    for path in (home, temporary, cache):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    return {
        "HOME": str(home),
        "TMPDIR": str(temporary),
        "XDG_CACHE_HOME": str(cache),
        "UV_CACHE_DIR": str(cache / "uv"),
    }


def _clean_generator_commit(project_dir: Path) -> str:
    commit = _run(("git", "rev-parse", "HEAD"), cwd=project_dir)
    if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise FirmwareRuntimeError("runtime generator Git identity is invalid")
    changed = _run(
        ("git", "status", "--porcelain=v1", "--untracked-files=no"),
        cwd=project_dir,
    )
    if changed:
        raise FirmwareRuntimeError(
            "runtime candidates require a clean tracked Git checkout"
        )
    return commit


def _refresh_work_root(project_dir: Path) -> Path:
    """Return a symlink-free, project-private root for executable staging."""
    if project_dir.is_symlink() or not project_dir.is_dir():
        raise FirmwareRuntimeError("runtime refresh project directory is unsafe")
    current = project_dir.resolve()
    for component in (".pio", "open-bike-build", "runtime-refresh"):
        current /= component
        if os.path.lexists(current):
            if current.is_symlink() or not current.is_dir():
                raise FirmwareRuntimeError(
                    f"runtime refresh work directory is unsafe: {current}"
                )
        else:
            current.mkdir(mode=0o700)
    return current


def _validate_wheel_archive(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise FirmwareRuntimeError(f"wheel is missing or unsafe: {path}")
    try:
        with zipfile.ZipFile(path) as archive:
            names: set[str] = set()
            casefolded: dict[str, str] = {}
            entries = archive.infolist()
            if not entries:
                raise FirmwareRuntimeError(f"wheel is empty: {path.name}")
            for info in entries:
                raw_name = info.filename
                name = raw_name[:-1] if info.is_dir() else raw_name
                member = PurePosixPath(name)
                collision = casefolded.get(name.casefold())
                mode = info.external_attr >> 16
                file_type = stat.S_IFMT(mode)
                if (
                    not name
                    or "\\" in name
                    or unicodedata.normalize("NFC", name) != name
                    or member.is_absolute()
                    or any(part in {"", ".", ".."} for part in member.parts)
                    or member.as_posix() != name
                    or raw_name in names
                    or collision is not None
                    or info.flag_bits & 0x1
                    or file_type not in {0, stat.S_IFREG, stat.S_IFDIR}
                    or (info.is_dir() and file_type == stat.S_IFREG)
                    or (not info.is_dir() and file_type == stat.S_IFDIR)
                ):
                    detail = collision or raw_name
                    raise FirmwareRuntimeError(
                        f"wheel contains an unsafe or colliding member: "
                        f"{path.name} {detail!r}"
                    )
                names.add(raw_name)
                casefolded[name.casefold()] = name
    except zipfile.BadZipFile as error:
        raise FirmwareRuntimeError(f"wheel is not a valid ZIP: {path.name}") from error


def _normalize_wheel(path: Path) -> None:
    _validate_wheel_archive(path)
    temporary = path.with_suffix(".normalized")
    with zipfile.ZipFile(path) as source, zipfile.ZipFile(
        temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as output:
        for name in sorted(source.namelist()):
            info = source.getinfo(name)
            if info.is_dir():
                continue
            normalized = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            normalized.compress_type = zipfile.ZIP_DEFLATED
            normalized.external_attr = info.external_attr
            output.writestr(normalized, source.read(name))
    os.replace(temporary, path)
    _validate_wheel_archive(path)


def _wheel_identity(path: Path) -> tuple[str, str, list[str], str | None]:
    _validate_wheel_archive(path)
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise FirmwareRuntimeError(f"wheel contains duplicate members: {path.name}")
        metadata_names = [
            name
            for name in names
            if len(PurePosixPath(name).parts) == 2
            and PurePosixPath(name).parts[0].endswith(".dist-info")
            and PurePosixPath(name).parts[1] == "METADATA"
        ]
        wheel_names = [
            name
            for name in names
            if len(PurePosixPath(name).parts) == 2
            and PurePosixPath(name).parts[0].endswith(".dist-info")
            and PurePosixPath(name).parts[1] == "WHEEL"
        ]
        if len(metadata_names) != 1 or len(wheel_names) != 1:
            raise FirmwareRuntimeError(f"wheel metadata is ambiguous: {path.name}")
        metadata = BytesParser().parsebytes(archive.read(metadata_names[0]))
        wheel = BytesParser().parsebytes(archive.read(wheel_names[0]))
    name, version = metadata.get("Name"), metadata.get("Version")
    tags = wheel.get_all("Tag") or []
    license_expression = metadata.get("License-Expression") or metadata.get("License")
    if not name or not version or not tags:
        raise FirmwareRuntimeError(f"wheel identity is incomplete: {path.name}")
    return _normalize_name(name), version, sorted(tags), license_expression


def _reviewed_wheel_license(
    path: Path,
    name: str,
    version: str,
    metadata_license: str | None,
    overrides: Mapping[tuple[str, str], Mapping[str, object]],
) -> tuple[str, dict[str, object], bool]:
    _validate_wheel_archive(path)
    if metadata_license is not None and metadata_license.strip() and (
        metadata_license.strip().casefold() not in {"unknown", "unlicensed"}
    ):
        return metadata_license.strip(), {"kind": "wheel-metadata"}, False
    key = (name, version)
    override = overrides.get(key)
    if override is None:
        raise FirmwareRuntimeError(
            f"wheel license is not reviewed: {name}=={version}"
        )
    evidence = []
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            for evidence_name in override["evidenceFiles"]:
                if names.count(evidence_name) != 1:
                    raise FirmwareRuntimeError(
                        f"wheel license evidence is missing or ambiguous: "
                        f"{name}=={version} {evidence_name}"
                    )
                info = archive.getinfo(evidence_name)
                mode = info.external_attr >> 16
                if info.is_dir() or stat.S_ISLNK(mode):
                    raise FirmwareRuntimeError(
                        f"wheel license evidence is unsafe: "
                        f"{name}=={version} {evidence_name}"
                    )
                contents = archive.read(info)
                if not contents.strip():
                    raise FirmwareRuntimeError(
                        f"wheel license evidence is empty: "
                        f"{name}=={version} {evidence_name}"
                    )
                evidence.append(
                    {
                        "path": evidence_name,
                        "sha256": hashlib.sha256(contents).hexdigest(),
                    }
                )
    except zipfile.BadZipFile as error:
        raise FirmwareRuntimeError(
            f"wheel license evidence could not be read: {path.name}"
        ) from error
    return (
        str(override["license"]),
        {"kind": "tracked-override", "files": evidence},
        True,
    )


def _pypi_wheel_source(
    name: str,
    version: str,
    filename: str,
    environment: Mapping[str, str],
) -> tuple[str, str]:
    url = (
        "https://pypi.org/pypi/"
        f"{urllib.parse.quote(name, safe='')}/"
        f"{urllib.parse.quote(version, safe='')}/json"
    )
    raw = _run(
        (
            "/usr/bin/curl",
            "--disable",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--tlsv1.2",
            url,
        ),
        environment=environment,
    )
    try:
        value = json.loads(raw, object_pairs_hook=_duplicate_key_rejector)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise FirmwareRuntimeError(
            f"PyPI provenance is invalid for {filename}"
        ) from error
    if not isinstance(value, dict) or not isinstance(value.get("urls"), list):
        raise FirmwareRuntimeError(f"PyPI provenance is invalid for {filename}")
    matches = [
        item
        for item in value["urls"]
        if isinstance(item, dict) and item.get("filename") == filename
    ]
    if len(matches) != 1:
        raise FirmwareRuntimeError(f"PyPI provenance is missing for {filename}")
    source_url = matches[0].get("url")
    digests = matches[0].get("digests")
    source_sha = digests.get("sha256") if isinstance(digests, dict) else None
    if (
        not isinstance(source_url, str)
        or not source_url.startswith("https://files.pythonhosted.org/")
        or not isinstance(source_sha, str)
        or re.fullmatch(r"[0-9a-f]{64}", source_sha) is None
    ):
        raise FirmwareRuntimeError(f"PyPI provenance is invalid for {filename}")
    return source_url, source_sha


def _write_wrapper(path: Path, module: str) -> None:
    path.write_text(
        "#!/bin/sh\n"
        "set -eu\n"
        "root=$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd)\n"
        f'exec "$root/python/bin/python3" -m {module} "$@"\n',
        encoding="utf-8",
    )
    path.chmod(0o755)


def _write_uv_wrapper(path: Path) -> None:
    path.write_text(
        "#!/bin/sh\n"
        "set -eu\n"
        "root=$(CDPATH= cd -- \"$(dirname -- \"$0\")/..\" && pwd)\n"
        'exec "$root/python/bin/uv" "$@"\n',
        encoding="utf-8",
    )
    path.chmod(0o755)


def _remove_generated_python_state(root: Path, baseline_bin: set[str]) -> None:
    python_bin = root / "python/bin"
    for path in sorted(python_bin.iterdir()):
        if path.name not in baseline_bin and path.name != "uv":
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
    for path in sorted(root.rglob("__pycache__"), reverse=True):
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
    for path in root.rglob("*.pyc"):
        path.unlink()
    for record in sorted((root / "python").rglob("*.dist-info/RECORD")):
        with record.open(encoding="utf-8", newline="") as stream:
            rows = [
                row
                for row in csv.reader(stream)
                if row
                and (
                    not row[0].startswith("../")
                    or PurePosixPath(row[0]).name == "uv"
                )
            ]
        with record.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream, lineterminator="\n")
            writer.writerows(sorted(rows, key=lambda row: row[0]))

    # python-build-standalone includes a platform terminfo database even though
    # none of the locked firmware tools use it. Some Linux entries differ only
    # by case, so they cannot be represented safely by the canonical runtime
    # inventory on case-insensitive filesystems. Remove the entire unused data
    # set instead of weakening the cross-host collision check.
    terminfo = root / "python/share/terminfo"
    if terminfo.exists() or terminfo.is_symlink():
        if terminfo.is_symlink() or not terminfo.is_dir():
            raise FirmwareRuntimeError(
                "candidate runtime terminfo path is not a real directory"
            )
        shutil.rmtree(terminfo)


def _reject_path_leaks(root: Path, forbidden_paths: Sequence[Path]) -> None:
    needles = {
        str(path).encode()
        for candidate in forbidden_paths
        for path in (candidate, candidate.resolve())
        if str(path)
    }
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            overlap = b""
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                value = overlap + chunk
                if any(needle in value for needle in needles):
                    raise FirmwareRuntimeError(
                        f"candidate runtime leaks a refresh path: {path.relative_to(root)}"
                    )
                overlap = value[-4096:]


def _inventory(root: Path) -> dict[str, object]:
    files = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or (not path.is_file() and not path.is_dir()):
            raise FirmwareRuntimeError(f"candidate runtime contains an unsafe member: {path}")
        if not path.is_file() or path.name == "inventory.json":
            continue
        relative = path.relative_to(root).as_posix()
        files.append({
            "path": relative,
            "size": path.stat().st_size,
            "sha256": _sha256(path),
            "executable": bool(path.stat().st_mode & stat.S_IXUSR),
        })
    return {"schema": 1, "files": files}


def _bundle(root: Path, output: Path) -> None:
    inventory = _inventory(root)
    (root / "inventory.json").write_bytes(_canonical(inventory))
    with output.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                for path in sorted(root.rglob("*")):
                    if not path.is_file():
                        continue
                    info = archive.gettarinfo(str(path), arcname=path.relative_to(root).as_posix())
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    info.mode = 0o755 if os.access(path, os.X_OK) else 0o644
                    with path.open("rb") as stream:
                        archive.addfile(info, stream)


def build_candidate(project_dir: Path, target_id: str, output_dir: Path, release_tag: str) -> dict[str, object]:
    inputs, wheel_license_overrides, refresh_path, licenses_path = _load_inputs(
        project_dir
    )
    generator_commit = _clean_generator_commit(project_dir)
    lock = load_lock(project_dir / "tools/firmware-runtime/lock-v1.json")
    matches = [target for target in lock.targets if target.target_id == target_id]
    if len(matches) != 1:
        raise FirmwareRuntimeError(f"unknown runtime refresh target: {target_id}")
    target = matches[0]
    python_source = _require_matching_python_provenance(inputs, target)
    from firmware_runtime import host_target_id
    if host_target_id() != target_id:
        raise FirmwareRuntimeError(f"candidate {target_id} must be built on its matching host")
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="open-bike-runtime-", dir=_refresh_work_root(project_dir)
    ) as temporary_name:
        temporary = Path(temporary_name)
        command_environment = _isolated_command_environment(
            temporary / "command-environment"
        )
        _download_artifact(
            python_source,
            temporary / "Python-3.13.15.tar.xz",
            environment=command_environment,
        )
        python_archive = temporary / "python.tar.gz"
        _download_artifact(
            target.python, python_archive, environment=command_environment
        )
        staging = temporary / "runtime"
        staging.mkdir()
        python = _extract_python(python_archive, staging / "python")
        baseline_python_bin = {path.name for path in (staging / "python/bin").iterdir()}
        wheelhouse = staging / "wheelhouse"
        wheelhouse.mkdir()
        sets = inputs["distributionSets"]
        requirements_dir = staging / "requirements"
        requirements_dir.mkdir()
        for set_name in GROUP_NAMES:
            (requirements_dir / REQUIREMENT_FILENAMES[set_name]).write_text(
                "\n".join(sets[set_name]) + "\n",
                encoding="utf-8",
            )
        source_names = set(inputs["sources"])
        for set_name in GROUP_NAMES:
            requirements = sorted(
                (
                    item
                    for item in sets[set_name]
                    if _normalize_name(item.split("==", 1)[0]) not in source_names
                ),
                key=str.casefold,
            )
            if requirements:
                _run((str(python), "-m", "pip", "--isolated", "download", "--index-url", "https://pypi.org/simple", "--disable-pip-version-check", "--no-cache-dir", "--no-deps", "--only-binary=:all:", "--dest", str(wheelhouse), *requirements), environment=command_environment)
        for wheel_path in sorted(wheelhouse.glob("*.whl")):
            _validate_wheel_archive(wheel_path)
        downloaded_identities: dict[tuple[str, str], Path] = {}
        for wheel_path in sorted(wheelhouse.glob("*.whl")):
            name, version, _, _ = _wheel_identity(wheel_path)
            key = (name, version)
            if key in downloaded_identities or name in source_names:
                raise FirmwareRuntimeError(
                    f"unexpected or duplicate downloaded wheel: {name}=={version}"
                )
            downloaded_identities[key] = wheel_path
        pypi_sources: dict[tuple[str, str], tuple[str, str]] = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            pending = {
                executor.submit(
                    _pypi_wheel_source,
                    name,
                    version,
                    wheel_path.name,
                    command_environment,
                ): (name, version)
                for (name, version), wheel_path in downloaded_identities.items()
            }
            for future in concurrent.futures.as_completed(pending):
                key = pending[future]
                source_url, source_sha = future.result()
                if source_sha != _sha256(downloaded_identities[key]):
                    raise FirmwareRuntimeError(
                        "downloaded wheel hash disagrees with PyPI before install: "
                        f"{downloaded_identities[key].name}"
                    )
                pypi_sources[key] = (source_url, source_sha)
        top_requirements = sets["topLevel"]
        _run((str(python), "-m", "pip", "--isolated", "install", "--disable-pip-version-check", "--no-cache-dir", "--no-index", "--find-links", str(wheelhouse), "--no-deps", *top_requirements), environment=command_environment)
        setuptools_version = _run(
            (
                str(python),
                "-c",
                "import importlib.metadata; print(importlib.metadata.version('setuptools'))",
            ),
            environment=command_environment,
        )
        source_paths = {
            "pioarduino-core": temporary / "pioarduino-core.zip",
            "esptool": temporary / "esptool-5.1.0.tar.gz",
        }
        for source_name, source in inputs["sources"].items():
            source_archive = source_paths[source_name]
            _download_artifact(
                Artifact(source["url"], source["size"], source["sha256"]),
                source_archive,
                environment=command_environment,
            )
            before = set(wheelhouse.glob("*.whl"))
            _run((str(python), "-m", "pip", "--isolated", "wheel", "--disable-pip-version-check", "--no-cache-dir", "--no-build-isolation", "--no-deps", "--wheel-dir", str(wheelhouse), str(source_archive)), environment=command_environment)
            built = set(wheelhouse.glob("*.whl")) - before
            if len(built) != 1:
                raise FirmwareRuntimeError(f"{source_name} did not produce one wheel")
            _normalize_wheel(built.pop())
        bin_dir = staging / "bin"
        bin_dir.mkdir()
        _write_wrapper(bin_dir / "pio", "platformio")
        _write_uv_wrapper(bin_dir / "uv")
        pio_version = _run((str(bin_dir / "pio"), "--version"), environment=command_environment)
        uv_version = _run((str(bin_dir / "uv"), "--version"), environment=command_environment)
        _run((str(python), "-m", "pip", "--isolated", "check"), environment=command_environment)
        identities: dict[tuple[str, str], tuple[Path, list[str], str | None]] = {}
        for wheel_path in sorted(wheelhouse.glob("*.whl")):
            name, version, tags, license_expression = _wheel_identity(wheel_path)
            key = (name, version)
            if key in identities:
                raise FirmwareRuntimeError(f"duplicate wheel identity: {name}=={version}")
            identities[key] = (wheel_path, tags, license_expression)
        set_members: dict[str, list[str]] = {}
        wheel_groups: dict[str, str] = {}
        for set_name in GROUP_NAMES:
            members = []
            for requirement in sets[set_name]:
                raw_name, version = requirement.split("==", 1)
                key = (_normalize_name(raw_name), version)
                if key not in identities:
                    raise FirmwareRuntimeError(f"candidate is missing {requirement}")
                filename = identities[key][0].name
                members.append(filename)
                wheel_groups.setdefault(filename, GROUP_LABELS[set_name])
            set_members[set_name] = sorted(members)
        wheels = []
        license_rows = []
        used_license_overrides: set[tuple[str, str]] = set()
        for (name, version), (wheel_path, tags, license_expression) in sorted(identities.items()):
            if name in inputs["sources"]:
                source = inputs["sources"][name]
                source_url, source_sha = source["url"], source["sha256"]
            else:
                source_url, source_sha = pypi_sources[(name, version)]
                if source_sha != _sha256(wheel_path):
                    raise FirmwareRuntimeError(f"downloaded wheel hash disagrees with PyPI: {wheel_path.name}")
            wheels.append({
                "filename": wheel_path.name,
                "normalizedName": name,
                "version": version,
                "tags": tags,
                "size": wheel_path.stat().st_size,
                "sha256": _sha256(wheel_path),
                "sourceUrl": source_url,
                "sourceSha256": source_sha,
                "group": wheel_groups[wheel_path.name],
            })
            reviewed_license, license_evidence, used_override = _reviewed_wheel_license(
                wheel_path,
                name,
                version,
                license_expression,
                wheel_license_overrides,
            )
            if used_override:
                used_license_overrides.add((name, version))
            license_rows.append(
                {
                    "name": name,
                    "version": version,
                    "license": reviewed_license,
                    "evidence": license_evidence,
                }
            )
        if used_license_overrides != set(wheel_license_overrides):
            missing = sorted(set(wheel_license_overrides) - used_license_overrides)
            raise FirmwareRuntimeError(
                "runtime wheel license overrides were not used by this candidate: "
                + ", ".join(f"{name}=={version}" for name, version in missing)
            )
        distribution_sets = {
            name: {
                "wheels": set_members[name],
                "sha256": hashlib.sha256(_canonical(set_members[name])).hexdigest(),
            }
            for name in GROUP_NAMES
        }
        bundle_name = f"open-bike-firmware-runtime-{target_id}.tar.gz"
        bundle_path = output_dir / bundle_name
        _remove_generated_python_state(staging, baseline_python_bin)
        _reject_path_leaks(staging, (temporary, project_dir))
        _bundle(staging, bundle_path)
        target_contract = {
            "id": target.target_id,
            "os": target.os_name,
            "architecture": target.architecture,
            "pythonVersion": target.python_version,
            "abi": target.abi,
            "minimumPlatformTag": target.minimum_platform_tag,
            "accepted": True,
            "python": {
                "url": target.python.url,
                "size": target.python.size,
                "sha256": target.python.sha256,
                "license": inputs["pythonSource"]["license"],
                "source": {
                    key: inputs["pythonSource"][key]
                    for key in ("url", "size", "sha256")
                },
                "builder": inputs["pythonBuilder"],
            },
            "bundle": {
                "url": f"https://github.com/seichris/open-bike-computer/releases/download/{release_tag}/{bundle_name}",
                "size": bundle_path.stat().st_size,
                "sha256": _sha256(bundle_path),
            },
            "contents": {
                "platformioVersion": inputs["platformio"],
                "wheels": wheels,
                "distributionSets": distribution_sets,
                "platform": {
                    "archiveSha256": WAVESHARE_PLATFORM_ARCHIVE_SHA256,
                    "packagesSha256": WAVESHARE_PLATFORM_PACKAGES_SHA256,
                },
            },
        }
        evidence = {
            "schema": 1,
            "target": target_id,
            "refreshInputsSha256": _sha256(refresh_path),
            "licensesSha256": _sha256(licenses_path),
            "platformioOutput": pio_version,
            "setuptoolsVersion": setuptools_version,
            "uvOutput": uv_version,
            "pythonLicense": target.python.license,
            "pythonSourceSha256": python_source.sha256,
            "pythonBuilderCommit": target.python.builder.commit,
            "networkDisabledReplayCommand": ["uv", "pip", "install", "--offline", "--no-cache", "--find-links", "wheelhouse"],
            "wheelCount": len(wheels),
            "bundleSha256": target_contract["bundle"]["sha256"],
        }
        contract = {
            "schema": 1,
            "generator": {
                "version": "2",
                "commit": generator_commit,
                "refreshInputsSha256": _sha256(refresh_path),
                "licensesSha256": _sha256(licenses_path),
            },
            "target": target_contract,
        }
        evidence["generatorCommit"] = contract["generator"]["commit"]
        (output_dir / f"contract-{target_id}.json").write_bytes(_canonical(contract))
        (output_dir / f"evidence-{target_id}.json").write_bytes(_canonical(evidence))
        (output_dir / f"licenses-{target_id}.json").write_bytes(
            _canonical({"schema": LICENSE_REPORT_SCHEMA, "wheels": license_rows})
        )
        return contract


def _installed_distributions(python: Path, environment: Mapping[str, str]) -> dict[str, str]:
    raw = _run(
        (
            str(python),
            "-c",
            "import importlib.metadata,json;"
            "print(json.dumps(sorted((d.metadata['Name'],d.version) "
            "for d in importlib.metadata.distributions())))",
        ),
        environment=environment,
    )
    rows = json.loads(raw)
    if not isinstance(rows, list):
        raise FirmwareRuntimeError("offline replay distribution output is invalid")
    result: dict[str, str] = {}
    for row in rows:
        if (
            not isinstance(row, list)
            or len(row) != 2
            or not all(isinstance(value, str) and value for value in row)
        ):
            raise FirmwareRuntimeError("offline replay distribution output is invalid")
        name = _normalize_name(row[0])
        if name in result:
            raise FirmwareRuntimeError(f"offline replay has duplicate distribution: {name}")
        result[name] = row[1]
    return result


def verify_candidate(project_dir: Path, target_id: str, candidate_dir: Path) -> dict[str, object]:
    inputs, _, refresh_path, _ = _load_inputs(project_dir)
    contract_path = candidate_dir / f"contract-{target_id}.json"
    bundle_path = candidate_dir / f"open-bike-firmware-runtime-{target_id}.tar.gz"
    if (
        contract_path.is_symlink()
        or not contract_path.is_file()
        or bundle_path.is_symlink()
        or not bundle_path.is_file()
    ):
        raise FirmwareRuntimeError("candidate contract or bundle is missing or unsafe")
    contract_wrapper = _load_candidate_contract(
        project_dir, contract_path, expected_target=target_id
    )
    contract = contract_wrapper["target"]
    with tempfile.TemporaryDirectory(
        prefix="open-bike-runtime-replay-", dir=_refresh_work_root(project_dir)
    ) as temporary_name:
        temporary = Path(temporary_name)
        candidate_lock = {
            "schema": 1,
            "lockSetId": "candidate-offline-replay",
            "generator": {
                "version": "2",
                "commit": "0" * 40,
                "refreshInputsSha256": _sha256(refresh_path),
                "licensesSha256": "0" * 64,
            },
            "targets": [contract],
        }
        lock_path = temporary / "lock.json"
        lock_path.write_bytes(_canonical(candidate_lock))
        target = select_target(load_lock(lock_path), target_id)
        if target.bundle is None or target.contents is None:
            raise FirmwareRuntimeError("candidate contract is not accepted")
        if (
            bundle_path.stat().st_size != target.bundle.size
            or _sha256(bundle_path) != target.bundle.sha256
        ):
            raise FirmwareRuntimeError("candidate bundle disagrees with its contract")
        runtime = temporary / "runtime"
        extract_verified_bundle(bundle_path, runtime)
        provenance = _verify_runtime_tree(runtime, target)
        replay_environment = _isolated_command_environment(
            temporary / "command-environment"
        )
        replay_environment["UV_CACHE_DIR"] = str(temporary / "empty-uv-cache")
        pio_output = _run((str(runtime / "bin/pio"), "--version"), environment=replay_environment)
        uv_output = _run((str(runtime / "bin/uv"), "--version"), environment=replay_environment)
        observed: dict[str, dict[str, str]] = {}
        for set_name, requirements_name in (
            ("pioarduinoRoot", "pioarduino-root.txt"),
            ("espIdf", "esp-idf.txt"),
        ):
            environment_root = temporary / set_name
            environment_python = environment_root / "bin/python"
            _run(
                (
                    str(runtime / "bin/uv"),
                    "venv",
                    "--clear",
                    "--python",
                    str(runtime / "python/bin/python3"),
                    str(environment_root),
                ),
                environment=replay_environment,
            )
            _run(
                (
                    str(runtime / "bin/uv"),
                    "pip",
                    "install",
                    "--offline",
                    "--no-cache",
                    "--find-links",
                    str(runtime / "wheelhouse"),
                    "--python",
                    str(environment_python),
                    "--requirements",
                    str(runtime / "requirements" / requirements_name),
                ),
                environment=replay_environment,
            )
            _run(
                (
                    str(runtime / "bin/uv"),
                    "pip",
                    "check",
                    "--python",
                    str(environment_python),
                ),
                environment=replay_environment,
            )
            distributions = _installed_distributions(
                environment_python, replay_environment
            )
            expected = {
                _normalize_name(requirement.split("==", 1)[0]): requirement.split("==", 1)[1]
                for requirement in inputs["distributionSets"][set_name]
            }
            if distributions != expected:
                raise FirmwareRuntimeError(
                    f"offline replay distribution set changed for {set_name}"
                )
            observed[set_name] = distributions
        return {
            "schema": 1,
            "target": target_id,
            "bundleSha256": target.bundle.sha256,
            "runtimeTreeSha256": provenance.tree_sha256,
            "platformioOutput": pio_output,
            "uvOutput": uv_output,
            "distributionCounts": {
                name: len(distributions) for name, distributions in observed.items()
            },
            "uvCacheStartedEmpty": True,
            "networkDisabled": True,
        }


def _load_candidate_contract(
    project_dir: Path, path: Path, *, expected_target: str | None = None
) -> dict[str, object]:
    _, _, refresh, licenses = _load_inputs(project_dir)
    if path.is_symlink() or not path.is_file():
        raise FirmwareRuntimeError(f"candidate contract is missing or unsafe: {path}")
    try:
        raw = path.read_bytes()
        value = json.loads(raw, object_pairs_hook=_duplicate_key_rejector)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FirmwareRuntimeError(f"candidate contract is invalid: {error}") from error
    if raw != _canonical(value):
        raise FirmwareRuntimeError("candidate contract is not canonical UTF-8 JSON")
    if not isinstance(value, dict) or set(value) != {"schema", "generator", "target"} or value.get("schema") != 1:
        raise FirmwareRuntimeError("candidate contract schema is invalid")
    generator = value["generator"]
    if (
        not isinstance(generator, dict)
        or set(generator)
        != {"version", "commit", "refreshInputsSha256", "licensesSha256"}
        or generator.get("version") != "2"
        or not isinstance(generator.get("commit"), str)
        or re.fullmatch(r"[0-9a-f]{40}", generator["commit"]) is None
        or generator.get("refreshInputsSha256") != _sha256(refresh)
        or generator.get("licensesSha256") != _sha256(licenses)
    ):
        raise FirmwareRuntimeError("candidate generator identity is invalid")
    target = value["target"]
    if not isinstance(target, dict) or (
        expected_target is not None and target.get("id") != expected_target
    ):
        raise FirmwareRuntimeError("candidate target identity is invalid")
    return value


def assemble_lock(project_dir: Path, contracts: Sequence[Path], output: Path, lock_set_id: str) -> dict[str, object]:
    _, _, refresh, licenses = _load_inputs(project_dir)
    wrappers = [_load_candidate_contract(project_dir, path) for path in contracts]
    targets = [wrapper["target"] for wrapper in wrappers]
    if len(targets) != 2 or {target.get("id") for target in targets} != {"linux-x86_64-cp313", "macos-arm64-cp313"}:
        raise FirmwareRuntimeError("accepted lock requires exactly both reviewed host contracts")
    generators = {json.dumps(wrapper["generator"], sort_keys=True) for wrapper in wrappers}
    if len(generators) != 1:
        raise FirmwareRuntimeError("accepted runtime candidates have different generators")
    generator = wrappers[0]["generator"]
    value = {
        "schema": 1,
        "lockSetId": lock_set_id,
        "generator": {
            "version": generator["version"],
            "commit": generator["commit"],
            "refreshInputsSha256": _sha256(refresh),
            "licensesSha256": _sha256(licenses),
        },
        "targets": sorted(targets, key=lambda item: item["id"]),
    }
    if output.is_symlink() or (output.exists() and not output.is_file()):
        raise FirmwareRuntimeError("accepted lock output is unsafe")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=output.parent,
            prefix=f".{output.name}.",
            delete=False,
        ) as stream:
            temporary_name = stream.name
            stream.write(_canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        temporary = Path(temporary_name)
        load_lock(temporary)
        temporary.chmod(0o644)
        os.replace(temporary, output)
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass
    return value


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=(
            "inspect-inputs",
            "verify-python",
            "build-candidate",
            "verify-candidate",
            "assemble-lock",
        ),
    )
    parser.add_argument("--project-dir", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--target")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--release-tag")
    parser.add_argument("--contract", type=Path, action="append", default=[])
    parser.add_argument("--lock-set-id")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        if args.command == "inspect-inputs":
            result = inspect_inputs(args.project_dir)
        elif args.command == "verify-python":
            if not args.target or args.output is None:
                raise FirmwareRuntimeError("verify-python requires --target and --output")
            result = verify_python_input(args.project_dir, args.target, args.output)
        elif args.command == "build-candidate":
            if not args.target or args.output_dir is None or not args.release_tag:
                raise FirmwareRuntimeError("build-candidate requires --target, --output-dir, and --release-tag")
            result = build_candidate(args.project_dir, args.target, args.output_dir, args.release_tag)
        elif args.command == "verify-candidate":
            if not args.target or args.output_dir is None:
                raise FirmwareRuntimeError(
                    "verify-candidate requires --target and --output-dir"
                )
            result = verify_candidate(args.project_dir, args.target, args.output_dir)
        else:
            if args.output is None or not args.lock_set_id or not args.contract:
                raise FirmwareRuntimeError("assemble-lock requires --output, --lock-set-id, and --contract")
            result = assemble_lock(args.project_dir, args.contract, args.output, args.lock_set_id)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (FirmwareRuntimeError, OSError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print(f"Runtime refresh failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
