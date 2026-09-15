#!/usr/bin/env python3
"""Capture and compare AMOLED build evidence across two Git identities.

Whole verified firmware images intentionally embed the Git identity and source
timestamp.  This tool instead records the compiler outputs that must remain
identical for an e-paper-only change: line-marker-free preprocessed shared
translation units, every non-metadata application object, and the final linker
map after replacing only the absolute project root.  It also requires the
locked runtime, core, dependency, partition, and toolchain identities to agree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections.abc import Sequence
from pathlib import Path


SCHEMA = 1
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
    "libraryDependenciesSha256",
    "managedComponentsSha256",
    "bootloaderBinSha256",
    "partitionTableBinSha256",
    "bootApp0Sha256",
)
LINE_MARKER = re.compile(rb"^[ \t]*#[ \t]*(?:line[ \t]+)?[0-9]+(?:[ \t].*)?\r?$")


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
    lines = [line for line in raw.splitlines() if not LINE_MARKER.match(line)]
    return b"\n".join(lines) + (b"\n" if lines else b"")


def _normalized_map(path: Path, project_dir: Path) -> bytes:
    raw = _read_regular(path, "linker map")
    root = str(project_dir.resolve()).encode()
    if not root:
        raise EvidenceError("project root normalization is empty")
    return raw.replace(root, b"<PROJECT_ROOT>")


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


def _application_objects(build_dir: Path) -> dict[str, str]:
    if build_dir.is_symlink() or not build_dir.is_dir():
        raise EvidenceError(f"build directory is missing or unsafe: {build_dir}")
    objects: dict[str, str] = {}
    for path in sorted(build_dir.rglob("*.o")):
        if path.is_symlink() or not path.is_file():
            raise EvidenceError(f"object file is unsafe: {path}")
        relative = path.relative_to(build_dir).as_posix()
        # This is the sole object exclusion. It owns the intentionally
        # different embedded Git SHA and source timestamp.
        if relative.endswith("/firmware_metadata/firmware_metadata.cpp.o"):
            continue
        objects[relative] = _sha256(_read_regular(path, "object file"))
    if not objects:
        raise EvidenceError(f"no non-metadata object files found below {build_dir}")
    return objects


def _manifest_identity(manifest: dict[str, object]) -> dict[str, object]:
    identity = {field: manifest[field] for field in MANIFEST_IDENTITY_FIELDS}
    core = manifest.get("coreAttestation")
    if not isinstance(core, dict) or not core:
        raise EvidenceError("build manifest is missing coreAttestation")
    # Core paths are worktree-local. Compare every semantic/hash field while
    # replacing only the absolute directory locations.
    identity["coreAttestation"] = {
        key: value for key, value in core.items() if not key.endswith("Dir")
    }
    return identity


def capture(
    *,
    project_dir: Path,
    environment: str,
    preprocessed: dict[str, Path],
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
    map_bytes = _normalized_map(build_dir / "firmware.map", project_dir)
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
        "objectsSha256": _application_objects(build_dir),
        "linkerMapSha256": _sha256(map_bytes),
        "exclusions": {
            "object": ["*/firmware_metadata/firmware_metadata.cpp.o"],
            "linkerMapNormalization": ["absolute project root -> <PROJECT_ROOT>"],
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
