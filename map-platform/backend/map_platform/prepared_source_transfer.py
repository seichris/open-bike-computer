"""Chunked immutable transport for sealed source-preparation files.

The producer publishes all content-addressed chunks, then the manifest blob,
then one immutable slot document. A consumer never observes partial readiness.
This moves files between hosts; semantic validation belongs to the source and
calibration readers after restoration.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path

from .preparation_objects import PreparationObjectStore
from .strict_json import loads_strict_json

CHUNK_BYTES = 64 * 1024 * 1024
MAX_MANIFEST_BYTES = 8 * 1024 * 1024
MAX_CHUNKS = 20_000
MIN_FREE_BYTES = 2 * 1024 * 1024 * 1024


def _canonical(value: dict) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


class PreparedSourceTransfer:
    def __init__(self, remote: PreparationObjectStore, *, chunk_bytes: int = CHUNK_BYTES):
        if type(chunk_bytes) is not int or not 0 < chunk_bytes <= CHUNK_BYTES:
            raise ValueError("source preparation chunk size is invalid")
        self.remote = remote
        self.chunk_bytes = chunk_bytes

    def publish_file(self, kind: str, slot: str, source: Path) -> dict:
        before = source.stat()
        if not source.is_file() or source.is_symlink() or before.st_size <= 0:
            raise ValueError("sealed source preparation file is invalid")
        chunks = []
        full = hashlib.sha256()
        with tempfile.TemporaryDirectory(prefix="source-chunk-") as temporary:
            with source.open("rb") as stream:
                while data := stream.read(self.chunk_bytes):
                    if len(chunks) >= MAX_CHUNKS:
                        raise ValueError("source preparation file has too many chunks")
                    digest = hashlib.sha256(data).hexdigest()
                    full.update(data)
                    chunk_path = Path(temporary) / "chunk"
                    chunk_path.write_bytes(data)
                    self.remote.publish_blob(f"{kind}-chunk", chunk_path,
                                             sha256=digest, media_type="application/octet-stream")
                    chunks.append({"sha256": digest, "bytes": len(data)})
        after = source.stat()
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ):
            raise ValueError("source preparation file changed during publication")
        manifest = {
            "schemaVersion": 1,
            "fileSha256": full.hexdigest(),
            "fileBytes": before.st_size,
            "chunkBytes": self.chunk_bytes,
            "chunks": chunks,
        }
        raw = _canonical(manifest)
        if len(raw) > MAX_MANIFEST_BYTES:
            raise ValueError("source preparation manifest exceeds its size limit")
        digest = hashlib.sha256(raw).hexdigest()
        with tempfile.TemporaryDirectory(prefix="source-manifest-") as temporary:
            path = Path(temporary) / "manifest.json"
            path.write_bytes(raw)
            self.remote.publish_blob(f"{kind}-manifest", path, sha256=digest,
                                     media_type="application/json")
        self.remote.publish_document(kind, slot, {
            "schemaVersion": 1,
            "manifestSha256": digest,
            "manifestBytes": len(raw),
            "fileSha256": manifest["fileSha256"],
            "fileBytes": manifest["fileBytes"],
        })
        return manifest

    def restore_file(self, kind: str, slot: str, destination: Path, *, max_bytes: int) -> dict | None:
        if type(max_bytes) is not int or max_bytes <= 0:
            raise ValueError("source preparation restore limit is invalid")
        pointer = self.remote.read_document(kind, slot)
        if pointer is None:
            return None
        if (set(pointer) != {"schemaVersion", "manifestSha256", "manifestBytes", "fileSha256", "fileBytes"}
                or pointer["schemaVersion"] != 1
                or type(pointer["manifestBytes"]) is not int
                or not 0 < pointer["manifestBytes"] <= MAX_MANIFEST_BYTES
                or type(pointer["fileBytes"]) is not int
                or not 0 < pointer["fileBytes"] <= max_bytes
                or any(not isinstance(pointer[key], str) or len(pointer[key]) != 64
                       or any(character not in "0123456789abcdef" for character in pointer[key])
                       for key in ("manifestSha256", "fileSha256"))):
            raise ValueError("source preparation pointer is invalid")
        destination.parent.mkdir(parents=True, exist_ok=True)
        lock_path = destination.with_name(destination.name + ".restore.lock")
        with lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if destination.exists():
                if (destination.is_symlink() or destination.stat().st_size != pointer["fileBytes"]
                        or _sha256_file(destination) != pointer["fileSha256"]):
                    raise ValueError("local source preparation file differs from its receipt")
                return pointer
            if shutil.disk_usage(destination.parent).free < pointer["fileBytes"] + self.chunk_bytes + MIN_FREE_BYTES:
                raise ValueError("insufficient source preparation restore space")
            with tempfile.TemporaryDirectory(prefix="source-restore-", dir=destination.parent) as temporary:
                root = Path(temporary)
                manifest_path = root / "manifest.json"
                if not self.remote.restore_blob(
                    f"{kind}-manifest", manifest_path, sha256=pointer["manifestSha256"],
                    expected_bytes=pointer["manifestBytes"],
                ):
                    raise ValueError("source preparation manifest blob is missing")
                raw = manifest_path.read_bytes()
                manifest = loads_strict_json(raw, description="source preparation manifest")
                self._validate_manifest(manifest, raw, pointer)
                staged = root / "file"
                full = hashlib.sha256()
                with staged.open("xb") as output:
                    for index, entry in enumerate(manifest["chunks"]):
                        chunk_path = root / f"chunk-{index}"
                        if not self.remote.restore_blob(
                            f"{kind}-chunk", chunk_path, sha256=entry["sha256"],
                            expected_bytes=entry["bytes"],
                        ):
                            raise ValueError("source preparation chunk is missing")
                        with chunk_path.open("rb") as stream:
                            while data := stream.read(1024 * 1024):
                                full.update(data)
                                output.write(data)
                        chunk_path.unlink()
                    output.flush()
                    os.fsync(output.fileno())
                if staged.stat().st_size != pointer["fileBytes"] or full.hexdigest() != pointer["fileSha256"]:
                    raise ValueError("source preparation file differs from its manifest")
                os.replace(staged, destination)
                descriptor = os.open(destination.parent, os.O_RDONLY)
                try:
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
                return pointer

    def _validate_manifest(self, manifest: dict, raw: bytes, pointer: dict) -> None:
        if not isinstance(manifest, dict) or set(manifest) != {
            "schemaVersion", "fileSha256", "fileBytes", "chunkBytes", "chunks"
        } or manifest["schemaVersion"] != 1 or _canonical(manifest) != raw:
            raise ValueError("source preparation manifest is invalid")
        if (manifest["fileSha256"] != pointer["fileSha256"]
                or manifest["fileBytes"] != pointer["fileBytes"]
                or type(manifest["chunkBytes"]) is not int
                or not 0 < manifest["chunkBytes"] <= CHUNK_BYTES
                or not isinstance(manifest["chunks"], list)
                or not 0 < len(manifest["chunks"]) <= MAX_CHUNKS):
            raise ValueError("source preparation manifest identity is invalid")
        total = 0
        for position, entry in enumerate(manifest["chunks"]):
            if (not isinstance(entry, dict) or set(entry) != {"sha256", "bytes"}
                    or not isinstance(entry["sha256"], str) or len(entry["sha256"]) != 64
                    or any(character not in "0123456789abcdef" for character in entry["sha256"])
                    or type(entry["bytes"]) is not int
                    or not 0 < entry["bytes"] <= manifest["chunkBytes"]
                    or (position < len(manifest["chunks"]) - 1
                        and entry["bytes"] != manifest["chunkBytes"])):
                raise ValueError("source preparation chunk receipt is invalid")
            total += entry["bytes"]
        if total != manifest["fileBytes"]:
            raise ValueError("source preparation chunk size total is invalid")
