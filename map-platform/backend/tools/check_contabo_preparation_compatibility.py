#!/usr/bin/env python3
"""Opt-in Contabo compatibility check using only disposable objects."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import uuid
from pathlib import Path

from map_platform.artifacts import ArtifactStoreError
from map_platform.preparation_objects import create_preparation_store_from_environment


def main() -> int:
    if os.environ.get("MAP_PLATFORM_PREPARATION_SPIKE_CONFIRM") != "delete-disposable-object":
        raise SystemExit("set MAP_PLATFORM_PREPARATION_SPIKE_CONFIRM=delete-disposable-object to run")
    remote = create_preparation_store_from_environment()
    if remote is None:
        raise SystemExit("configure MAP_PLATFORM_PREPARATION_STORE=contabo-s3")
    kind = "compatibility-spike"
    slot = hashlib.sha256(uuid.uuid4().bytes).hexdigest()
    # Match the source-preparation chunk size rather than testing only a tiny
    # object that may follow a different provider path.
    body = (f"bicino-preparation-compatibility-v1 {slot}\n".encode() * 1_000_000)[:64 * 1024 * 1024]
    digest = hashlib.sha256(body).hexdigest()
    blob_key = remote._key(kind, digest)
    document_key = remote._key(kind, slot, document=True)
    created: list[str] = []
    with tempfile.TemporaryDirectory(prefix="contabo-preparation-spike-") as temporary:
        root = Path(temporary)
        source = root / "source.bin"
        source.write_bytes(body)
        try:
            # A successful PUT may still be followed by a failed HEAD. Track the
            # unique key before publishing so that this check cleans it up too.
            created.append(blob_key)
            remote.publish_blob(kind, source, sha256=digest, media_type="application/octet-stream")
            if remote.store.read_prefix(blob_key, maximum_bytes=32) != body[:32]:
                raise RuntimeError("Contabo range GET differs")
            destination = root / "restored.bin"
            if not remote.restore_blob(kind, destination, sha256=digest, expected_bytes=len(body)):
                raise RuntimeError("Contabo blob HEAD differs")
            if destination.read_bytes() != body:
                raise RuntimeError("Contabo streamed GET differs")
            created.append(document_key)
            remote.publish_document(kind, slot, {"slot": slot, "blobSha256": digest})
            if remote.read_document(kind, slot) != {"slot": slot, "blobSha256": digest}:
                raise RuntimeError("Contabo document round trip differs")
            try:
                remote.publish_document(kind, slot, {"slot": slot, "blobSha256": "0" * 64})
            except ArtifactStoreError:
                pass
            else:
                raise RuntimeError("Contabo immutable conflict was accepted")
        finally:
            for key in reversed(created):
                remote.store.delete(key)
    print(json.dumps({"status": "ok", "bytes": len(body),
                      "checks": ["conditional-put", "head", "range-get", "full-get", "document", "conflict", "delete"]},
                     sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
