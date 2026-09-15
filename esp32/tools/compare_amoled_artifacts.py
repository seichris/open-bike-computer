#!/usr/bin/env python3
"""Capture and compare AMOLED build evidence across two Git identities.

Whole verified firmware images intentionally embed the Git identity and source
timestamp.  This tool instead records the compiler outputs that must remain
program-equivalent for an e-paper-only change: line-marker-free preprocessed
shared translation units, every non-metadata application object after removing
debug-only sections, and the allocated code/data portion of the final linker
map.  It also requires the source-independent locked runtime, core, dependency,
partition, and toolchain identities to agree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from datetime import datetime, timezone
from pathlib import Path


SCHEMA = 2
ALLOWED_ENVIRONMENTS = {
    "WAVESHARE_AMOLED_175",
    "WAVESHARE_AMOLED_175_PRODUCTION",
    "WAVESHARE_AMOLED_206",
    "WAVESHARE_AMOLED_206_PRODUCTION",
}
REQUIRED_PREPROCESSED_SOURCES = {
    "lib/ble_navigation/ble_navigation.cpp",
    "lib/epaper_display/epaper_display.cpp",
    "lib/gui/src/epaper_ui.cpp",
    "lib/gui/src/mainScr.cpp",
    "lib/maps/src/maps.cpp",
}
MANIFEST_IDENTITY_FIELDS = (
    "runtimeProvenance",
    "coreInputKey",
    "platformArchiveSha256",
    "platformPackagesSha256",
    "managedComponentsSha256",
    "bootloaderBinSha256",
    "partitionTableBinSha256",
    "bootApp0Sha256",
)
CORE_ATTESTATION_IDENTITY_FIELDS = (
    "environment",
    "mcu",
    "memoryType",
    "arduinoBuilderSha256",
    "boardManifestSha256",
    "bootApp0Sha256",
    "espidfBuilderSha256",
    "esptoolUploaderSha256",
    "frameworkLibsPackageSha256",
    "frameworkPackageSha256",
    "frameworkSdkconfigSha256",
    "platformArchiveSha256",
    "platformManifestSha256",
    "platformPackageSha256",
    "platformPackagesSha256",
    "platformTreeSha256",
    "toolsTreeSha256",
)
LINE_MARKER = re.compile(rb"^[ \t]*#[ \t]*(?:line[ \t]+)?[0-9]+(?:[ \t].*)?\r?$")
OUTPUT_SECTION = re.compile(
    rb"^(\.[^ \t]+)[ \t]+0x([0-9a-fA-F]+)[ \t]+0x([0-9a-fA-F]+)(?:[ \t].*)?$"
)


class EvidenceError(ValueError):
    """Raised when evidence is incomplete, unsafe, or not equivalent."""


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _read_regular(path: Path, label: str) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise EvidenceError(f"{label} is missing or unsafe: {path}")
    try:
        return path.read_bytes()
    except OSError as error:
        raise EvidenceError(f"could not read {label}: {path}: {error}") from error


def _load_object(path: Path, label: str) -> dict[str, object]:
    raw = _read_regular(path, label)
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"{label} is not valid JSON: {path}") from error
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must be a JSON object: {path}")
    return value


def _normalized_preprocessed(path: Path) -> bytes:
    raw = _read_regular(path, "preprocessed translation unit")
    lines = [
        line
        for line in raw.splitlines()
        if not LINE_MARKER.match(line) and line.strip()
    ]
    return b"\n".join(lines) + (b"\n" if lines else b"")


def _provenance_literals(manifest: dict[str, object]) -> tuple[bytes, ...]:
    literals: list[bytes] = []
    for field in ("sourceIdentity", "buildTimestamp", "sourceDateEpoch"):
        value = manifest.get(field)
        if isinstance(value, (str, int)) and str(value):
            literals.append(str(value).encode())
    timestamp = manifest.get("buildTimestamp")
    if isinstance(timestamp, str):
        try:
            parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
            parsed = parsed.astimezone(timezone.utc)
            literals.extend(
                (
                    f"{parsed:%b} {parsed.day:2d} {parsed.year:04d}".encode(),
                    f"{parsed:%H:%M:%S}".encode(),
                )
            )
        except ValueError as error:
            raise EvidenceError("build manifest has an invalid buildTimestamp") from error
    return tuple(dict.fromkeys(literals))


def _normalize_provenance_literals(
    data: bytes, manifest: dict[str, object]
) -> bytes:
    for literal in _provenance_literals(manifest):
        data = data.replace(literal, b"@" * len(literal))
    return data


def _normalized_map(
    path: Path, project_dir: Path, manifest: dict[str, object]
) -> bytes:
    raw = _read_regular(path, "linker map")
    root = str(project_dir.resolve()).encode()
    if not root:
        raise EvidenceError("project root normalization is empty")
    raw = _normalize_provenance_literals(raw.replace(root, b"<PROJECT_ROOT>"), manifest)
    in_memory_map = False
    capture_section = False
    lines: list[bytes] = []
    for line in raw.splitlines():
        if not in_memory_map:
            if line == b"Linker script and memory map":
                in_memory_map = True
            continue
        match = OUTPUT_SECTION.match(line)
        if match:
            section = match.group(1)
            address = int(match.group(2), 16)
            capture_section = address != 0 and not section.startswith(b".debug")
        if capture_section:
            lines.append(line)
    if not lines:
        raise EvidenceError("linker map lacks allocated code/data sections")
    return b"\n".join(lines) + b"\n"


def _relative_source(value: str) -> str:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or not value:
        raise EvidenceError(f"source path must be project-relative: {value!r}")
    return path.as_posix()


def _parse_preprocessed(values: Sequence[str]) -> dict[str, Path]:
    parsed: dict[str, Path] = {}
    for value in values:
        source, separator, filename = value.partition("=")
        if not separator or not filename:
            raise EvidenceError(
                "--preprocessed values must use project/source.cpp=output.ii"
            )
        source = _relative_source(source)
        if source in parsed:
            raise EvidenceError(f"duplicate preprocessed source: {source}")
        parsed[source] = Path(filename)
    missing = sorted(REQUIRED_PREPROCESSED_SOURCES - set(parsed))
    extra = sorted(set(parsed) - REQUIRED_PREPROCESSED_SOURCES)
    if missing or extra:
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if extra:
            details.append("unexpected " + ", ".join(extra))
        raise EvidenceError("preprocessed source set is incomplete: " + "; ".join(details))
    return parsed


def _application_objects(
    build_dir: Path, objcopy: Path, manifest: dict[str, object]
) -> dict[str, str]:
    if build_dir.is_symlink() or not build_dir.is_dir():
        raise EvidenceError(f"build directory is missing or unsafe: {build_dir}")
    if (
        objcopy.is_symlink()
        or not objcopy.is_file()
        or not os.access(objcopy, os.X_OK)
    ):
        raise EvidenceError(f"locked objcopy is missing or unsafe: {objcopy}")
    objects: dict[str, str] = {}
    with tempfile.TemporaryDirectory(prefix="amoled-object-normalization-") as temporary:
        normalized_root = Path(temporary)
        for index, path in enumerate(sorted(build_dir.rglob("*.o"))):
            if path.is_symlink() or not path.is_file():
                raise EvidenceError(f"object file is unsafe: {path}")
            relative = path.relative_to(build_dir).as_posix()
            # This is the sole object exclusion. It owns the intentionally
            # different embedded Git SHA and source timestamp.
            if relative.endswith("/firmware_metadata/firmware_metadata.cpp.o"):
                continue
            normalized = normalized_root / f"{index}.o"
            result = subprocess.run(
                [str(objcopy), "--strip-debug", str(path), str(normalized)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if result.returncode != 0:
                detail = result.stderr.decode(errors="replace").strip()
                raise EvidenceError(
                    f"locked objcopy could not normalize {relative}: {detail}"
                )
            data = _read_regular(normalized, "debug-stripped object file")
            objects[relative] = _sha256(
                _normalize_provenance_literals(data, manifest)
            )
    if not objects:
        raise EvidenceError(f"no non-metadata object files found below {build_dir}")
    return objects


def _manifest_identity(manifest: dict[str, object]) -> dict[str, object]:
    identity = {field: manifest[field] for field in MANIFEST_IDENTITY_FIELDS}
    core = manifest.get("coreAttestation")
    if not isinstance(core, dict) or not core:
        raise EvidenceError("build manifest is missing coreAttestation")
    missing = [field for field in CORE_ATTESTATION_IDENTITY_FIELDS if field not in core]
    if missing:
        raise EvidenceError(
            "coreAttestation is missing immutable identity fields: "
            + ", ".join(missing)
        )
    # Generated core/runtime trees can contain timestamp-keyed Python bytecode
    # and other source-build state. Their complete hashes are validated by the
    # wrapper for each build, while cross-commit isolation compares only the
    # immutable tool/package/config identities and the source-independent key.
    identity["coreAttestation"] = {
        field: core[field] for field in CORE_ATTESTATION_IDENTITY_FIELDS
    }
    return identity


def capture(
    *,
    project_dir: Path,
    environment: str,
    preprocessed: dict[str, Path],
    objcopy: Path,
) -> dict[str, object]:
    if environment not in ALLOWED_ENVIRONMENTS:
        raise EvidenceError(f"unsupported AMOLED equivalence environment: {environment}")
    project_dir = project_dir.resolve()
    manifest_path = (
        project_dir
        / ".pio/open-bike-build/builds"
        / environment
        / "current.json"
    )
    manifest = _load_object(manifest_path, "verified build manifest")
    if manifest.get("environment") != environment:
        raise EvidenceError("build manifest references another environment")
    if manifest.get("uploadEligible") is not True:
        raise EvidenceError("build manifest is not upload-eligible")
    source_identity = manifest.get("sourceIdentity")
    if not isinstance(source_identity, str) or not re.fullmatch(
        r"[0-9a-f]{40}", source_identity
    ):
        raise EvidenceError("build manifest lacks an exact clean Git identity")
    for field in MANIFEST_IDENTITY_FIELDS:
        if field not in manifest:
            raise EvidenceError(f"build manifest is missing {field}")

    build_dir = project_dir / ".pio/build" / environment
    map_bytes = _normalized_map(
        build_dir / "firmware.map", project_dir, manifest
    )
    preprocessed_hashes = {
        source: _sha256(_normalized_preprocessed(path))
        for source, path in sorted(preprocessed.items())
    }
    return {
        "schema": SCHEMA,
        "environment": environment,
        "sourceIdentity": source_identity,
        "manifestIdentity": _manifest_identity(manifest),
        "preprocessedSha256": preprocessed_hashes,
        "objectsSha256": _application_objects(build_dir, objcopy, manifest),
        "linkerMapSha256": _sha256(map_bytes),
        "exclusions": {
            "object": ["*/firmware_metadata/firmware_metadata.cpp.o"],
            "objectNormalization": [
                "debug-only sections removed by locked objcopy --strip-debug",
                "exact source identity and source timestamp literals -> same-length @ bytes",
            ],
            "preprocessedNormalization": [
                "compiler line markers removed",
                "blank lines removed",
            ],
            "linkerMapNormalization": [
                "absolute project root -> <PROJECT_ROOT>",
                "exact source identity and source timestamp literals -> same-length @ bytes",
                "only non-zero-address allocated section blocks retained",
            ],
            "wholeFirmware": (
                "not compared because verified images embed sourceIdentity and "
                "buildTimestamp; no binary bytes were normalized"
            ),
        },
    }


def _validated_evidence(label: str, evidence: dict[str, object]) -> None:
    required = {
        "schema",
        "environment",
        "sourceIdentity",
        "manifestIdentity",
        "preprocessedSha256",
        "objectsSha256",
        "linkerMapSha256",
        "exclusions",
    }
    if set(evidence) != required:
        raise EvidenceError(f"{label} evidence fields are incomplete or unknown")
    if evidence.get("schema") != SCHEMA:
        raise EvidenceError(f"{label} evidence has an unsupported schema")
    if evidence.get("environment") not in ALLOWED_ENVIRONMENTS:
        raise EvidenceError(f"{label} evidence has an unsupported environment")
    if not isinstance(evidence.get("sourceIdentity"), str) or not re.fullmatch(
        r"[0-9a-f]{40}", evidence["sourceIdentity"]
    ):
        raise EvidenceError(f"{label} evidence has an invalid source identity")
    if not isinstance(evidence.get("manifestIdentity"), dict):
        raise EvidenceError(f"{label} evidence has invalid manifest identity")
    preprocessed = evidence.get("preprocessedSha256")
    if (
        not isinstance(preprocessed, dict)
        or set(preprocessed) != REQUIRED_PREPROCESSED_SOURCES
        or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
               for value in preprocessed.values())
    ):
        raise EvidenceError(f"{label} evidence has invalid preprocessing hashes")
    objects = evidence.get("objectsSha256")
    if (
        not isinstance(objects, dict)
        or not objects
        or any(not isinstance(key, str) or not key or not isinstance(value, str)
               or not re.fullmatch(r"[0-9a-f]{64}", value)
               for key, value in objects.items())
    ):
        raise EvidenceError(f"{label} evidence has invalid object hashes")
    if not isinstance(evidence.get("linkerMapSha256"), str) or not re.fullmatch(
        r"[0-9a-f]{64}", evidence["linkerMapSha256"]
    ):
        raise EvidenceError(f"{label} evidence has an invalid linker-map hash")
    if not isinstance(evidence.get("exclusions"), dict):
        raise EvidenceError(f"{label} evidence has invalid exclusions")


def compare(baseline: dict[str, object], candidate: dict[str, object]) -> dict[str, object]:
    for label, evidence in (("baseline", baseline), ("candidate", candidate)):
        _validated_evidence(label, evidence)
    environment = baseline["environment"]
    failures: list[str] = []
    if candidate["environment"] != environment:
        failures.append("environment")
    if baseline.get("sourceIdentity") == candidate.get("sourceIdentity"):
        failures.append("source identities are not distinct")
    for field in (
        "manifestIdentity",
        "preprocessedSha256",
        "objectsSha256",
        "linkerMapSha256",
        "exclusions",
    ):
        if baseline.get(field) != candidate.get(field):
            failures.append(field)
    return {
        "schema": SCHEMA,
        "status": "pass" if not failures else "fail",
        "environment": environment,
        "baselineSourceIdentity": baseline.get("sourceIdentity"),
        "candidateSourceIdentity": candidate.get("sourceIdentity"),
        "comparedObjectCount": len(baseline.get("objectsSha256", {})),
        "comparedPreprocessedCount": len(
            baseline.get("preprocessedSha256", {})
        ),
        "failures": failures,
    }


def _write_json(path: Path, value: dict[str, object]) -> None:
    if path.exists():
        raise EvidenceError(f"refusing to overwrite output: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--project-dir", type=Path, required=True)
    capture_parser.add_argument(
        "--environment", choices=sorted(ALLOWED_ENVIRONMENTS), required=True
    )
    capture_parser.add_argument(
        "--objcopy",
        type=Path,
        required=True,
        help="locked target objcopy used to remove debug-only object sections",
    )
    capture_parser.add_argument(
        "--preprocessed",
        action="append",
        default=[],
        metavar="SOURCE=OUTPUT",
        help="line-marker-free compiler preprocessing evidence; repeat once per shared TU",
    )
    capture_parser.add_argument("--output", type=Path, required=True)

    compare_parser = subparsers.add_parser("compare")
    compare_parser.add_argument("--baseline", type=Path, required=True)
    compare_parser.add_argument("--candidate", type=Path, required=True)
    compare_parser.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "capture":
            evidence = capture(
                project_dir=args.project_dir,
                environment=args.environment,
                preprocessed=_parse_preprocessed(args.preprocessed),
                objcopy=args.objcopy,
            )
            _write_json(args.output, evidence)
            print(
                "AMOLED_EQUIVALENCE_CAPTURE "
                f"environment={evidence['environment']} "
                f"git={evidence['sourceIdentity']} "
                f"objects={len(evidence['objectsSha256'])} "
                f"preprocessed={len(evidence['preprocessedSha256'])}"
            )
            return 0

        baseline = _load_object(args.baseline, "baseline evidence")
        candidate = _load_object(args.candidate, "candidate evidence")
        report = compare(baseline, candidate)
        _write_json(args.output, report)
        print(
            "AMOLED_EQUIVALENCE_RESULT "
            f"environment={report['environment']} status={report['status']} "
            f"objects={report['comparedObjectCount']} "
            f"preprocessed={report['comparedPreprocessedCount']}"
        )
        return 0 if report["status"] == "pass" else 1
    except (EvidenceError, OSError) as error:
        print(f"AMOLED equivalence failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
