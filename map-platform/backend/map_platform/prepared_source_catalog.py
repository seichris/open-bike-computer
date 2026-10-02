"""Contabo catalog for sealed OSM index and calibration generations."""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shutil
import tarfile
import tempfile
from pathlib import Path

from .building_identity import (
    BUILDING_SOURCE_INDEX_ALGORITHM_VERSION,
    BUILDING_SOURCE_INDEX_SCHEMA_VERSION,
    calibration_generation_from_manifest,
    calibration_generation_manifest_path,
    canonical_json,
)
from .preparation_objects import PreparationObjectStore
from .prepared_source_transfer import MIN_FREE_BYTES, PreparedSourceTransfer
from .strict_json import loads_strict_json

_SHA = re.compile(r"[0-9a-f]{64}")
MAX_CALIBRATION_CELL_BYTES = 32 * 1024 * 1024
MAX_CALIBRATION_MANIFEST_BYTES = 32 * 1024 * 1024


def source_index_location(cache_root: Path, source_sha256: str) -> tuple[str, Path]:
    if not _SHA.fullmatch(source_sha256):
        raise ValueError("source snapshot identity is invalid")
    identity = {
        "schemaVersion": BUILDING_SOURCE_INDEX_SCHEMA_VERSION,
        "algorithmVersion": BUILDING_SOURCE_INDEX_ALGORITHM_VERSION,
        "creationTool": "open-bike-building-source-index",
        "sourceSnapshotSha256": source_sha256,
    }
    key = hashlib.sha256(canonical_json(identity)).hexdigest()
    return key, cache_root / f"building-source-index-v{BUILDING_SOURCE_INDEX_SCHEMA_VERSION}" / source_sha256 / key


class PreparedSourceCatalog:
    def __init__(self, remote: PreparationObjectStore, *, chunk_bytes: int | None = None):
        self.remote = remote
        self.transfer = PreparedSourceTransfer(remote, **({"chunk_bytes": chunk_bytes} if chunk_bytes else {}))

    def publish_index(self, cache_root: Path, source_sha256: str) -> dict:
        key, root = source_index_location(cache_root, source_sha256)
        manifest = loads_strict_json((root / "manifest.json").read_bytes(), description="source index manifest")
        self._validate_index_manifest(manifest, key, source_sha256)
        receipt = self.transfer.publish_file("source-index", key, root / "index.sqlite")
        if receipt["fileSha256"] != manifest["databaseSha256"]:
            raise ValueError("source index database changed after validation")
        self.remote.publish_document("source-index-ready", key, manifest)
        return manifest

    def restore_index(self, cache_root: Path, source_sha256: str, *, max_bytes: int) -> Path | None:
        key, root = source_index_location(cache_root, source_sha256)
        manifest = self.remote.read_document("source-index-ready", key)
        if manifest is None:
            return None
        self._validate_index_manifest(manifest, key, source_sha256)
        root.mkdir(parents=True, exist_ok=True)
        receipt = self.transfer.restore_file("source-index", key, root / "index.sqlite", max_bytes=max_bytes)
        if receipt is None or receipt["fileSha256"] != manifest["databaseSha256"]:
            raise ValueError("source index ready document has no matching database")
        target = root / "manifest.json"
        raw = canonical_json(manifest) + b"\n"
        if target.exists():
            if target.read_bytes() != raw:
                raise ValueError("local source index manifest differs from Contabo")
        else:
            with tempfile.NamedTemporaryFile(prefix="source-index-manifest-", dir=root, delete=False) as temporary:
                temporary.write(raw)
                temporary.flush()
                os.fsync(temporary.fileno())
                staged = Path(temporary.name)
            os.replace(staged, target)
        return target

    @staticmethod
    def _validate_index_manifest(manifest: dict, key: str, source_sha256: str) -> None:
        if not isinstance(manifest, dict) or set(manifest) != {
            "schemaVersion", "algorithmVersion", "creationTool", "sourceSnapshotSha256",
            "indexKey", "databaseSha256", "nodeCount", "wayCount", "relationCount",
            "relationMemberCount", "manifestSha256",
        }:
            raise ValueError("source index manifest fields are invalid")
        digest = manifest["manifestSha256"]
        body = {name: value for name, value in manifest.items() if name != "manifestSha256"}
        if (not isinstance(digest, str) or not _SHA.fullmatch(digest)
                or hashlib.sha256(canonical_json(body)).hexdigest() != digest
                or manifest["sourceSnapshotSha256"] != source_sha256
                or manifest["indexKey"] != key
                or manifest["schemaVersion"] != BUILDING_SOURCE_INDEX_SCHEMA_VERSION
                or manifest["algorithmVersion"] != BUILDING_SOURCE_INDEX_ALGORITHM_VERSION
                or manifest["creationTool"] != "open-bike-building-source-index"
                or not isinstance(manifest["databaseSha256"], str)
                or not _SHA.fullmatch(manifest["databaseSha256"])):
            raise ValueError("source index manifest identity is invalid")
        for name in ("nodeCount", "wayCount", "relationCount", "relationMemberCount"):
            if type(manifest[name]) is not int or manifest[name] < 0:
                raise ValueError("source index manifest counts are invalid")

    def publish_calibration(self, cache_root: Path, identity: dict) -> dict:
        manifest_path = calibration_generation_manifest_path(cache_root, identity)
        generation = calibration_generation_from_manifest(
            manifest_path, source_snapshot_sha256=identity["sourceSnapshotSha256"],
            calibration_key=identity["calibrationKey"], calibration_identity=identity,
        )
        raw = loads_strict_json(manifest_path.read_bytes(), description="calibration manifest")
        with tempfile.TemporaryDirectory(prefix="calibration-archive-") as temporary:
            archive = Path(temporary) / "calibration.tar"
            with tarfile.open(archive, "w") as output:
                self._add_archive_file(output, manifest_path, "manifest.json", MAX_CALIBRATION_MANIFEST_BYTES)
                for entry in raw["cells"]:
                    x, y = entry["x"], entry["y"]
                    name = f"cells/{x}/{y}.json"
                    cell_path = manifest_path.parent / name
                    if cell_path.is_symlink():
                        raise ValueError("source calibration cell is a symlink")
                    cell_bytes = cell_path.read_bytes()
                    self._validate_calibration_cell_bytes(cell_bytes, entry)
                    self._add_archive_bytes(output, cell_bytes, name, MAX_CALIBRATION_CELL_BYTES)
            self.transfer.publish_file("source-calibration", identity["calibrationKey"], archive)
        return generation

    @staticmethod
    def _add_archive_file(archive: tarfile.TarFile, path: Path, name: str, limit: int) -> None:
        if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= limit:
            raise ValueError("source calibration artifact is invalid")
        PreparedSourceCatalog._add_archive_bytes(archive, path.read_bytes(), name, limit)

    @staticmethod
    def _add_archive_bytes(archive: tarfile.TarFile, data: bytes, name: str, limit: int) -> None:
        if not 0 < len(data) <= limit:
            raise ValueError("source calibration artifact exceeds its size limit")
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = 0o600
        info.mtime = 0
        archive.addfile(info, io.BytesIO(data))

    @staticmethod
    def _validate_calibration_cell_bytes(raw: bytes, entry: dict) -> None:
        cell = loads_strict_json(raw, description="calibration cell")
        if (not isinstance(cell, dict)
                or cell.get("cellX") != entry["x"] or cell.get("cellY") != entry["y"]
                or cell.get("entrySha256") != entry["entrySha256"]
                or hashlib.sha256(canonical_json({
                    key: value for key, value in cell.items() if key != "entrySha256"
                })).hexdigest() != entry["entrySha256"]):
            raise ValueError("calibration cell differs from its sealed manifest")

    def restore_calibration(self, cache_root: Path, identity: dict, *, max_bytes: int) -> Path | None:
        manifest_path = calibration_generation_manifest_path(cache_root, identity)
        root = manifest_path.parent
        if root.exists():
            if manifest_path.is_file():
                calibration_generation_from_manifest(
                    manifest_path, source_snapshot_sha256=identity["sourceSnapshotSha256"],
                    calibration_key=identity["calibrationKey"], calibration_identity=identity,
                )
                return manifest_path
            raise ValueError("local calibration generation is incomplete")
        root.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="calibration-restore-", dir=root.parent) as temporary:
            temporary_root = Path(temporary)
            archive = temporary_root / "calibration.tar"
            receipt = self.transfer.restore_file(
                "source-calibration", identity["calibrationKey"], archive, max_bytes=max_bytes,
            )
            if receipt is None:
                return None
            extracted = temporary_root / "extracted"
            extracted.mkdir()
            with tarfile.open(archive, "r:") as source:
                members = source.getmembers()
                if not members or members[0].name != "manifest.json":
                    raise ValueError("calibration archive manifest is missing")
                first = members[0]
                if not first.isfile() or not 0 < first.size <= MAX_CALIBRATION_MANIFEST_BYTES:
                    raise ValueError("calibration archive manifest is invalid")
                manifest_bytes = source.extractfile(first).read()
                (extracted / "manifest.json").write_bytes(manifest_bytes)
                calibration_generation_from_manifest(
                    extracted / "manifest.json", source_snapshot_sha256=identity["sourceSnapshotSha256"],
                    calibration_key=identity["calibrationKey"], calibration_identity=identity,
                )
                manifest = loads_strict_json(manifest_bytes, description="calibration manifest")
                expected = [f"cells/{entry['x']}/{entry['y']}.json" for entry in manifest.get("cells", [])]
                if [member.name for member in members[1:]] != expected:
                    raise ValueError("calibration archive cells differ from manifest")
                extracted_bytes = sum(member.size for member in members)
                if extracted_bytes > max_bytes or shutil.disk_usage(root.parent).free < extracted_bytes + MIN_FREE_BYTES:
                    raise ValueError("insufficient calibration extraction space")
                for member, entry in zip(members[1:], manifest["cells"], strict=True):
                    if not member.isfile() or not 0 < member.size <= MAX_CALIBRATION_CELL_BYTES:
                        raise ValueError("calibration archive cell is invalid")
                    destination = extracted / member.name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with destination.open("xb") as output:
                        stream = source.extractfile(member)
                        while data := stream.read(1024 * 1024):
                            output.write(data)
                    self._validate_calibration_cell_bytes(destination.read_bytes(), entry)
            calibration_generation_from_manifest(
                extracted / "manifest.json", source_snapshot_sha256=identity["sourceSnapshotSha256"],
                calibration_key=identity["calibrationKey"], calibration_identity=identity,
            )
            os.replace(extracted, root)
        return manifest_path
