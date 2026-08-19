"""Read and validate canonical building-block cache receipts.

The extractor owns cache writes.  The coordinator only rereads the published
manifest and section bytes after the worker command returns; this keeps task
publication independent from the extractor's process memory.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping

from .building_scope import canonical_json
from .reuse import MapBlock


BUILDING_BLOCK_CACHE_SCHEMA_VERSION = 1
_SHA256 = re.compile(r"[0-9a-f]{64}")


class BuildingBlockReceiptError(RuntimeError):
    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)


@dataclass(frozen=True)
class BuildingBlockReceipt:
    block: MapBlock
    cache_identity_sha256: str
    content_sha256: str
    content_bytes: int
    manifest_sha256: str
    stats: Mapping[str, int]

    def producer_identity(self) -> dict[str, Any]:
        return {
            "cacheIdentitySha256": self.cache_identity_sha256,
            "manifestSha256": self.manifest_sha256,
        }

    def validation(self) -> dict[str, Any]:
        return {
            "schemaVersion": BUILDING_BLOCK_CACHE_SCHEMA_VERSION,
            "contentBytes": self.content_bytes,
            "contentSha256": self.content_sha256,
            "stats": dict(self.stats),
        }


def read_building_block_receipt(
    cache_root: str | Path,
    cache_identity: Mapping[str, Any],
    block: MapBlock,
) -> BuildingBlockReceipt:
    """Reread one cache manifest and section, failing closed on corruption."""

    if not isinstance(cache_identity, Mapping):
        raise BuildingBlockReceiptError(
            "building_block_cache_identity_invalid",
            "cache identity is not an object",
        )
    identity = dict(cache_identity)
    identity_sha256 = identity.get("cacheIdentitySha256")
    if not isinstance(identity_sha256, str) or not _SHA256.fullmatch(identity_sha256):
        raise BuildingBlockReceiptError(
            "building_block_cache_identity_invalid",
            "cache identity hash is invalid",
        )
    identity_body = {
        key: value
        for key, value in identity.items()
        if key != "cacheIdentitySha256"
    }
    if hashlib.sha256(canonical_json(identity_body)).hexdigest() != identity_sha256:
        raise BuildingBlockReceiptError(
            "building_block_cache_identity_invalid",
            "cache identity hash does not match its body",
        )
    if not isinstance(block, MapBlock):
        raise BuildingBlockReceiptError(
            "building_block_cache_invalid", "block coordinate is invalid"
        )
    source_sha256 = identity.get("sourceSnapshotSha256")
    rules_sha256 = identity.get("rulesSha256")
    if not _SHA256.fullmatch(str(source_sha256 or "")) or not _SHA256.fullmatch(
        str(rules_sha256 or "")
    ):
        raise BuildingBlockReceiptError(
            "building_block_cache_identity_invalid",
            "cache source or rules identity is invalid",
        )
    namespace = (
        Path(cache_root)
        / "building-block-v1"
        / str(source_sha256)
        / str(rules_sha256)
        / identity_sha256
    )
    manifest_path = namespace / "blocks" / f"{block.x}_{block.y}.json"
    try:
        manifest = json.loads(manifest_path.read_bytes())
    except (OSError, TypeError, ValueError) as exc:
        raise BuildingBlockReceiptError(
            "building_block_cache_missing", "building block manifest is unavailable"
        ) from exc
    if not isinstance(manifest, dict):
        raise BuildingBlockReceiptError(
            "building_block_cache_invalid", "building block manifest is invalid"
        )
    manifest_sha256 = manifest.get("manifestSha256")
    body = {
        key: value for key, value in manifest.items() if key != "manifestSha256"
    }
    section = manifest.get("section")
    block_document = manifest.get("block")
    if (
        set(manifest)
        != {"schemaVersion", "cacheIdentitySha256", "block", "section", "stats", "manifestSha256"}
        or manifest.get("schemaVersion") != BUILDING_BLOCK_CACHE_SCHEMA_VERSION
        or manifest.get("cacheIdentitySha256") != identity_sha256
        or not isinstance(manifest_sha256, str)
        or not _SHA256.fullmatch(manifest_sha256)
        or hashlib.sha256(canonical_json(body)).hexdigest() != manifest_sha256
        or not isinstance(block_document, dict)
        or block_document.get("x") != block.x
        or block_document.get("y") != block.y
        or block_document.get("boundsMeters")
        != [block.x * 4096, block.y * 4096, (block.x + 1) * 4096, (block.y + 1) * 4096]
        or not isinstance(section, dict)
        or set(section) != {"path", "bytes", "sha256"}
        or section.get("path") != f"sections/{section.get('sha256')}.bin"
        or not isinstance(section.get("bytes"), int)
        or isinstance(section.get("bytes"), bool)
        or section.get("bytes") <= 0
        or not isinstance(section.get("sha256"), str)
        or not _SHA256.fullmatch(section["sha256"])
    ):
        raise BuildingBlockReceiptError(
            "building_block_cache_invalid", "building block manifest failed validation"
        )
    section_path = namespace / section["path"]
    try:
        namespace_root = namespace.resolve()
        resolved_section = section_path.resolve()
        if namespace_root not in resolved_section.parents:
            raise BuildingBlockReceiptError(
                "building_block_cache_invalid", "building section escapes its namespace"
            )
        content = resolved_section.read_bytes()
    except BuildingBlockReceiptError:
        raise
    except OSError as exc:
        raise BuildingBlockReceiptError(
            "building_block_cache_missing", "building block section is unavailable"
        ) from exc
    if len(content) != section["bytes"] or hashlib.sha256(content).hexdigest() != section["sha256"]:
        raise BuildingBlockReceiptError(
            "building_block_cache_invalid", "building block section hash is invalid"
        )
    stats = manifest.get("stats")
    if not isinstance(stats, dict) or any(
        isinstance(value, bool) or not isinstance(value, int) or value < 0
        for value in stats.values()
    ):
        raise BuildingBlockReceiptError(
            "building_block_cache_invalid", "building block statistics are invalid"
        )
    return BuildingBlockReceipt(
        block=block,
        cache_identity_sha256=identity_sha256,
        content_sha256=section["sha256"],
        content_bytes=section["bytes"],
        manifest_sha256=manifest_sha256,
        stats=dict(stats),
    )


def read_building_block_receipts(
    cache_root: str | Path,
    cache_identity: Mapping[str, Any],
    blocks: Iterable[MapBlock],
) -> tuple[BuildingBlockReceipt, ...]:
    normalized = tuple(sorted(set(blocks)))
    if not normalized:
        raise BuildingBlockReceiptError(
            "building_block_cache_invalid", "no block receipts were requested"
        )
    return tuple(
        read_building_block_receipt(cache_root, cache_identity, block)
        for block in normalized
    )
