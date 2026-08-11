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
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from email.parser import BytesParser
from pathlib import Path, PurePosixPath
from typing import Mapping, Sequence

from firmware_runtime import (
    Artifact,
    FirmwareRuntimeError,
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
        ("/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--output", str(output), artifact.url),
        environment=environment,
    )
    if output.stat().st_size != artifact.size or _sha256(output) != artifact.sha256:
        raise FirmwareRuntimeError(f"downloaded refresh artifact failed verification: {artifact.url}")


def _normalize_name(value: str) -> str:
    result = "".join("-" if character in "_.-" else character.lower() for character in value)
    while "--" in result:
        result = result.replace("--", "-")
    return result.strip("-")


def _load_inputs(project_dir: Path) -> tuple[dict[str, object], Path, Path]:
    runtime_dir = project_dir / "tools/firmware-runtime"
    refresh = runtime_dir / "refresh-inputs.json"
    licenses = runtime_dir / "licenses.json"
    for path in (refresh, licenses):
        if path.is_symlink() or not path.is_file():
            raise FirmwareRuntimeError(f"runtime refresh input is missing or unsafe: {path}")
    value = json.loads(refresh.read_bytes())
    if not isinstance(value, dict) or value.get("schema") != 2:
        raise FirmwareRuntimeError("runtime refresh inputs must use schema 2")
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
            or not all(isinstance(item, str) and item.count("==") == 1 for item in requirements)
        ):
            raise FirmwareRuntimeError(f"runtime refresh set {name} is not exact and canonical")
    return value, refresh, licenses


def inspect_inputs(project_dir: Path) -> dict[str, object]:
    value, refresh, licenses = _load_inputs(project_dir)
    lock = load_lock(project_dir / "tools/firmware-runtime/lock-v1.json")
    return {
        "schema": 2,
        "lockSetId": lock.lock_set_id,
        "lockManifestSha256": lock.manifest_sha256,
        "refreshInputsSha256": _sha256(refresh),
        "licensesSha256": _sha256(licenses),
        "targets": [{"id": target.target_id, "accepted": target.accepted} for target in lock.targets],
        "distributionCounts": {name: len(value["distributionSets"][name]) for name in GROUP_NAMES},
    }


def verify_python_input(project_dir: Path, target_id: str, output: Path) -> dict[str, object]:
    lock = load_lock(project_dir / "tools/firmware-runtime/lock-v1.json")
    matches = [target for target in lock.targets if target.target_id == target_id]
    if len(matches) != 1:
        raise FirmwareRuntimeError(f"unknown runtime refresh target: {target_id}")
    target = matches[0]
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


def _normalize_wheel(path: Path) -> None:
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


def _wheel_identity(path: Path) -> tuple[str, str, list[str], str | None]:
    with zipfile.ZipFile(path) as archive:
        metadata_names = [
            name
            for name in archive.namelist()
            if len(PurePosixPath(name).parts) == 2
            and PurePosixPath(name).parts[0].endswith(".dist-info")
            and PurePosixPath(name).parts[1] == "METADATA"
        ]
        wheel_names = [
            name
            for name in archive.namelist()
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


def _pypi_wheel_source(name: str, version: str, filename: str, cafile: str) -> tuple[str, str]:
    import ssl

    context = ssl.create_default_context(cafile=cafile)
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context)
    )
    with opener.open(
        f"https://pypi.org/pypi/{name}/{version}/json", timeout=30
    ) as response:
        value = json.load(response)
    matches = [item for item in value.get("urls", []) if item.get("filename") == filename]
    if len(matches) != 1:
        raise FirmwareRuntimeError(f"PyPI provenance is missing for {filename}")
    return matches[0]["url"], matches[0]["digests"]["sha256"]


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
    inputs, refresh_path, licenses_path = _load_inputs(project_dir)
    lock = load_lock(project_dir / "tools/firmware-runtime/lock-v1.json")
    matches = [target for target in lock.targets if target.target_id == target_id]
    if len(matches) != 1:
        raise FirmwareRuntimeError(f"unknown runtime refresh target: {target_id}")
    target = matches[0]
    from firmware_runtime import host_target_id
    if host_target_id() != target_id:
        raise FirmwareRuntimeError(f"candidate {target_id} must be built on its matching host")
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="open-bike-runtime-") as temporary_name:
        temporary = Path(temporary_name)
        command_environment = _isolated_command_environment(
            temporary / "command-environment"
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
        cafile = _run((str(python), "-c", "import certifi; print(certifi.where())"), environment=command_environment)
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
        pypi_sources: dict[tuple[str, str], tuple[str, str]] = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            pending = {
                executor.submit(
                    _pypi_wheel_source,
                    name,
                    version,
                    wheel_path.name,
                    cafile,
                ): (name, version)
                for (name, version), (wheel_path, _, _) in identities.items()
                if name not in inputs["sources"]
            }
            for future in concurrent.futures.as_completed(pending):
                pypi_sources[pending[future]] = future.result()
        wheels = []
        license_rows = []
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
            license_rows.append({"name": name, "version": version, "license": license_expression or "UNKNOWN"})
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
        contract = {
            "id": target.target_id,
            "os": target.os_name,
            "architecture": target.architecture,
            "pythonVersion": target.python_version,
            "abi": target.abi,
            "minimumPlatformTag": target.minimum_platform_tag,
            "accepted": True,
            "python": {"url": target.python.url, "size": target.python.size, "sha256": target.python.sha256},
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
            "networkDisabledReplayCommand": ["uv", "pip", "install", "--offline", "--no-cache", "--find-links", "wheelhouse"],
            "wheelCount": len(wheels),
            "bundleSha256": contract["bundle"]["sha256"],
        }
        (output_dir / f"contract-{target_id}.json").write_bytes(_canonical(contract))
        (output_dir / f"evidence-{target_id}.json").write_bytes(_canonical(evidence))
        (output_dir / f"licenses-{target_id}.json").write_bytes(_canonical({"schema": 1, "wheels": license_rows}))
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
    inputs, refresh_path, _ = _load_inputs(project_dir)
    contract_path = candidate_dir / f"contract-{target_id}.json"
    bundle_path = candidate_dir / f"open-bike-firmware-runtime-{target_id}.tar.gz"
    if (
        contract_path.is_symlink()
        or not contract_path.is_file()
        or bundle_path.is_symlink()
        or not bundle_path.is_file()
    ):
        raise FirmwareRuntimeError("candidate contract or bundle is missing or unsafe")
    contract = json.loads(contract_path.read_bytes())
    with tempfile.TemporaryDirectory(prefix="open-bike-runtime-replay-") as temporary_name:
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


def assemble_lock(project_dir: Path, contracts: Sequence[Path], output: Path, lock_set_id: str) -> dict[str, object]:
    _, refresh, licenses = _load_inputs(project_dir)
    targets = [json.loads(path.read_bytes()) for path in contracts]
    if len(targets) != 2 or {target.get("id") for target in targets} != {"linux-x86_64-cp313", "macos-arm64-cp313"}:
        raise FirmwareRuntimeError("accepted lock requires exactly both reviewed host contracts")
    commit = _run(("git", "rev-parse", "HEAD"), cwd=project_dir)
    value = {
        "schema": 1,
        "lockSetId": lock_set_id,
        "generator": {
            "version": "2",
            "commit": commit,
            "refreshInputsSha256": _sha256(refresh),
            "licensesSha256": _sha256(licenses),
        },
        "targets": sorted(targets, key=lambda item: item["id"]),
    }
    output.write_bytes(_canonical(value))
    load_lock(output)
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
