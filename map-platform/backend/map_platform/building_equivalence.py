"""Byte-level equivalence checks for monolithic and chunked map runs."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re
from typing import Any, Mapping
import zipfile

from .building_scope import canonical_json


class BuildingEquivalenceError(ValueError):
    """Raised when two retained build records are not byte-equivalent."""


_SHA256 = re.compile(r"[0-9a-f]{64}")


def build_equivalence_record_from_zip(
    archive_path: str | Path,
    *,
    artifact_format: str = "zip-stored-v1",
) -> dict[str, Any]:
    """Materialize a byte-level build record from a published ZIP artifact.

    The record is intentionally limited to canonical FMB paths and the ZIP
    payload itself.  ZIP metadata, task IDs, and producer timings are not
    treated as building inputs; the archive digest still makes final artifact
    bytes part of the equivalence check.
    """

    if not isinstance(artifact_format, str) or not artifact_format:
        raise BuildingEquivalenceError("artifact format must be a non-empty string")
    path = Path(archive_path)
    try:
        archive_bytes = path.read_bytes()
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            names: set[str] = set()
            fmb_hashes: dict[str, str] = {}
            for info in infos:
                name = info.filename.replace("\\", "/")
                parts = name.split("/")
                if (
                    not name
                    or name.startswith("/")
                    or any(part in {"", ".", ".."} for part in parts)
                    or name in names
                ):
                    raise BuildingEquivalenceError(
                        "ZIP contains an unsafe or duplicate entry path"
                    )
                names.add(name)
                if info.is_dir() or not name.endswith(".fmb"):
                    continue
                payload = archive.read(info)
                if not payload:
                    raise BuildingEquivalenceError(
                        f"ZIP contains an empty FMB entry: {name}"
                    )
                fmb_hashes[name] = hashlib.sha256(payload).hexdigest()
    except BuildingEquivalenceError:
        raise
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        raise BuildingEquivalenceError(
            f"unable to read ZIP artifact: {path}"
        ) from exc

    if not fmb_hashes:
        raise BuildingEquivalenceError("ZIP contains no FMB entries")
    return {
        "fmbSha256ByPath": dict(sorted(fmb_hashes.items())),
        "artifacts": [
            {
                "format": artifact_format,
                "bytes": len(archive_bytes),
                "sha256": hashlib.sha256(archive_bytes).hexdigest(),
            }
        ],
    }


def _hashes(value: Any, label: str) -> dict[str, str]:
    if not isinstance(value, Mapping) or not value:
        raise BuildingEquivalenceError(f"{label} must be a non-empty object")
    result: dict[str, str] = {}
    for path, digest in value.items():
        if (
            not isinstance(path, str)
            or not path
            or not isinstance(digest, str)
            or _SHA256.fullmatch(digest) is None
        ):
            raise BuildingEquivalenceError(f"{label} contains an invalid hash")
        result[path] = digest
    return dict(sorted(result.items()))


def _artifact_payloads(record: Mapping[str, Any]) -> dict[str, tuple[int, str]]:
    artifacts = record.get("artifacts")
    if not isinstance(artifacts, list):
        raise BuildingEquivalenceError("build record artifacts must be a list")
    payloads: dict[str, tuple[int, str]] = {}
    for artifact in artifacts:
        if not isinstance(artifact, Mapping):
            raise BuildingEquivalenceError("build record artifact is not an object")
        format_name = artifact.get("format")
        byte_count = artifact.get("bytes")
        digest = artifact.get("sha256")
        if (
            not isinstance(format_name, str)
            or not format_name
            or type(byte_count) is not int
            or byte_count <= 0
            or not isinstance(digest, str)
            or _SHA256.fullmatch(digest) is None
        ):
            raise BuildingEquivalenceError("build record artifact payload is invalid")
        payload = (byte_count, digest)
        previous = payloads.get(format_name)
        if previous is not None and previous != payload:
            raise BuildingEquivalenceError(
                f"build record contains duplicate artifact format {format_name}"
            )
        payloads[format_name] = payload
    if not payloads:
        raise BuildingEquivalenceError("build record contains no artifact payloads")
    return dict(sorted(payloads.items()))


def validate_partition_equivalence(
    reference: Mapping[str, Any], candidate: Mapping[str, Any]
) -> dict[str, Any]:
    """Compare retained run records without trusting task or worker identity.

    ``fmbSha256ByPath`` is the canonical block-byte comparison.  Artifact
    payload bytes are compared by format when both records include them.  The
    comparison intentionally ignores task IDs, chunk boundaries, timing,
    cache-hit state, signatures, and producer metadata.
    """

    if not isinstance(reference, Mapping) or not isinstance(candidate, Mapping):
        raise BuildingEquivalenceError("build records must be objects")
    reference_blocks = _hashes(
        reference.get("fmbSha256ByPath"), "reference FMB hashes"
    )
    candidate_blocks = _hashes(
        candidate.get("fmbSha256ByPath"), "candidate FMB hashes"
    )
    if reference_blocks != candidate_blocks:
        missing = sorted(set(reference_blocks) - set(candidate_blocks))
        extra = sorted(set(candidate_blocks) - set(reference_blocks))
        changed = sorted(
            path
            for path in set(reference_blocks) & set(candidate_blocks)
            if reference_blocks[path] != candidate_blocks[path]
        )
        details = []
        if missing:
            details.append(f"missing blocks: {', '.join(missing[:8])}")
        if extra:
            details.append(f"extra blocks: {', '.join(extra[:8])}")
        if changed:
            details.append(f"changed blocks: {', '.join(changed[:8])}")
        raise BuildingEquivalenceError(
            "partitioned FMB bytes differ from the reference ("
            + "; ".join(details)
            + ")"
        )

    reference_artifacts = _artifact_payloads(reference)
    candidate_artifacts = _artifact_payloads(candidate)
    if reference_artifacts != candidate_artifacts:
        raise BuildingEquivalenceError(
            "partitioned artifact payload bytes differ from the reference"
        )

    block_digest = hashlib.sha256(
        canonical_json(reference_blocks)
    ).hexdigest()
    return {
        "schemaVersion": 1,
        "status": "pass",
        "blockCount": len(reference_blocks),
        "fmbSha256ByPathDigest": block_digest,
        "artifacts": {
            format_name: {
                "bytes": payload[0],
                "sha256": payload[1],
            }
            for format_name, payload in reference_artifacts.items()
        },
    }
