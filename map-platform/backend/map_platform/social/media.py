from __future__ import annotations

import hashlib
from io import BytesIO
import os
import warnings
from PIL import Image, ImageOps


def sanitize_avatar(data: bytes) -> dict[str, bytes]:
    if not data or len(data) > 5 * 1024 * 1024:
        raise ValueError("avatar_size")
    with warnings.catch_warnings():
        warnings.simplefilter("error", Image.DecompressionBombWarning)
        with Image.open(BytesIO(data)) as source:
            if (source.format not in {"JPEG", "PNG", "WEBP"}
                    or getattr(source, "n_frames", 1) != 1
                    or source.width * source.height > 16_000_000):
                raise ValueError("avatar_format")
            source.load()
            image = ImageOps.exif_transpose(source).convert("RGB")
            output = {}
            for name, size in (("profile", 256), ("marker", 96), ("hardware", 40)):
                # Copy pixels into a new image; no source metadata survives.
                cropped = ImageOps.fit(image, (size, size), method=Image.Resampling.LANCZOS)
                clean = Image.frombytes("RGB", cropped.size, cropped.tobytes())
                encoded = BytesIO()
                clean.save(encoded, format="PNG", optimize=True)
                output[name] = encoded.getvalue()
            return output


class S3Media:
    def __init__(self):
        import boto3
        self.bucket = os.environ["BICINO_SOCIAL_MEDIA_BUCKET"]
        self.client = boto3.client("s3", endpoint_url=os.environ.get("BICINO_SOCIAL_MEDIA_ENDPOINT"))

    def put(self, key: str, data: bytes):
        self.client.put_object(Bucket=self.bucket, Key=key, Body=data, ContentType="image/png",
                               Metadata={"sha256": hashlib.sha256(data).hexdigest()})

    def get(self, key: str) -> bytes:
        response = self.client.get_object(Bucket=self.bucket, Key=key)
        if response["ContentLength"] > 512000:
            response["Body"].close()
            raise ValueError("media_size")
        try:
            return response["Body"].read(512001)
        finally:
            response["Body"].close()

    def delete(self, key: str):
        self.client.delete_object(Bucket=self.bucket, Key=key)


class MemoryMedia:
    """Explicitly injected test fixture; never selected by production config."""
    def __init__(self):
        self.objects = {}

    def put(self, key, data):
        self.objects[key] = data

    def get(self, key):
        return self.objects[key]

    def delete(self, key):
        self.objects.pop(key, None)


def reconcile_orphans(database, media_store, now):
    """Dedicated private bucket: remove unreferenced uploads older than one day.

    Uploads use new UUID keys. The grace period excludes in-flight transactions;
    replacing a profile never rewrites an old key.
    """
    from sqlalchemy import select
    from .database import media
    if not isinstance(media_store, S3Media):
        return
    paginator = media_store.client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=media_store.bucket, Prefix="avatars/"):
        for item in page.get("Contents", []):
            key = item["Key"]
            if item["LastModified"].timestamp() >= now-86400:
                continue
            parts = key.split("/")
            if len(parts) != 4:
                continue
            with database.transaction() as c:
                asset = c.execute(select(media).where(media.c.id == parts[2])).mappings().first()
                referenced = asset and any(v["key"] == key for v in asset["variants"].values())
            if not referenced:
                media_store.delete(key)
