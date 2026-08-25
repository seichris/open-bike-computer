#!/usr/bin/env python3
"""Opt-in destructive compatibility spike against a disposable R2 prefix."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import uuid
from pathlib import Path

from map_platform.artifacts import (
    ArtifactStoreError,
    S3ArtifactStore,
    create_artifact_store_from_environment,
)


def main() -> int:
    if os.environ.get("MAP_PLATFORM_R2_SPIKE_CONFIRM") != "delete-disposable-object":
        raise SystemExit(
            "set MAP_PLATFORM_R2_SPIKE_CONFIRM=delete-disposable-object to run"
        )
    if os.environ.get("MAP_PLATFORM_ARTIFACT_STORE") != "s3":
        raise SystemExit("MAP_PLATFORM_ARTIFACT_STORE must be s3")
    with tempfile.TemporaryDirectory(prefix="r2-compatibility-") as temporary:
        root = Path(temporary)
        store = create_artifact_store_from_environment(root)
        if not isinstance(store, S3ArtifactStore):
            raise SystemExit("R2 spike requires the direct S3 artifact adapter")
        body = (b"bicino-r2-compatibility-v1\n" * 80_000)[:2_000_000]
        source = root / "sample.bin"
        source.write_bytes(body)
        digest = hashlib.sha256(body).hexdigest()
        object_key = f"compatibility-spike/{uuid.uuid4().hex}/sample.bin"
        try:
            store.put(
                source,
                object_key,
                sha256=digest,
                media_type="application/octet-stream",
            )
            if not store.verify(object_key, sha256=digest, expected_bytes=len(body)):
                raise RuntimeError("HEAD verification failed")
            if store.read_prefix(object_key, maximum_bytes=32) != body[:32]:
                raise RuntimeError("range GET verification failed")

            response = store.client.get_object(
                Bucket=store.bucket,
                Key=store._key(object_key),
            )
            downloaded = hashlib.sha256()
            downloaded_bytes = 0
            stream = response["Body"]
            try:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    downloaded.update(chunk)
                    downloaded_bytes += len(chunk)
            finally:
                stream.close()
            if downloaded_bytes != len(body) or downloaded.hexdigest() != digest:
                raise RuntimeError("full streamed GET verification failed")

            conflicting = root / "conflict.bin"
            conflicting.write_bytes(b"different")
            try:
                store.put(
                    conflicting,
                    object_key,
                    sha256=hashlib.sha256(b"different").hexdigest(),
                    media_type="application/octet-stream",
                )
            except ArtifactStoreError:
                pass
            else:
                raise RuntimeError("immutable conflict was not rejected")
        finally:
            deleted = store.delete(object_key)
        if not deleted or store.verify(object_key, sha256=digest, expected_bytes=len(body)):
            raise RuntimeError("disposable object deletion was not confirmed")
    print(
        json.dumps(
            {
                "status": "ok",
                "checksumMode": os.environ.get(
                    "MAP_PLATFORM_S3_CHECKSUM_MODE", "sha256"
                ),
                "bytes": len(body),
                "checks": ["put", "head", "range-get", "full-get", "conflict", "delete"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
