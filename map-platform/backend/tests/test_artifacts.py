from __future__ import annotations

import os
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from map_platform.artifacts import (
    ArtifactRecord,
    ArtifactStoreError,
    FileSystemArtifactStore,
    MAXIMUM_STREAM_ARTIFACT_BYTES,
    S3ArtifactStore,
    create_artifact_store_from_environment,
    sha256_file,
)


class FakeS3Error(Exception):
    def __init__(self, status: int, code: str):
        self.response = {
            "ResponseMetadata": {"HTTPStatusCode": status},
            "Error": {"Code": code},
        }
        super().__init__(code)


class FakeS3Client:
    def __init__(self):
        self.objects = {}
        self.put_calls = 0
        self.deleted = []
        self.conflicts_remaining = 0

    def head_object(self, *, Bucket, Key):
        try:
            value = self.objects[(Bucket, Key)]
        except KeyError as exc:
            raise FakeS3Error(404, "NoSuchKey") from exc
        return {
            "ContentLength": len(value["body"]),
            "Metadata": value["metadata"],
        }

    def put_object(self, **kwargs):
        if self.conflicts_remaining:
            self.conflicts_remaining -= 1
            raise FakeS3Error(409, "ConditionalRequestConflict")
        identity = (kwargs["Bucket"], kwargs["Key"])
        if kwargs.get("IfNoneMatch") == "*" and identity in self.objects:
            raise FakeS3Error(412, "PreconditionFailed")
        body = kwargs["Body"].read()
        self.objects[identity] = {
            "body": body,
            "metadata": kwargs["Metadata"],
            "content_type": kwargs["ContentType"],
            "checksum": kwargs["ChecksumSHA256"],
        }
        self.put_calls += 1

    def generate_presigned_url(self, method, *, Params, ExpiresIn, HttpMethod):
        return f"https://objects.invalid/{Params['Key']}?expires={ExpiresIn}&method={method}&http={HttpMethod}"

    def delete_object(self, *, Bucket, Key):
        self.deleted.append((Bucket, Key))
        self.objects.pop((Bucket, Key), None)


class ArtifactStoreTests(unittest.TestCase):
    def test_installed_boto3_model_supports_conditional_checksum_put(self):
        try:
            import boto3
        except ImportError:
            self.skipTest("boto3 is exercised by CI's object-storage dependency set")
        client = boto3.client(
            "s3",
            region_name="us-east-1",
            aws_access_key_id="test",
            aws_secret_access_key="test",
        )
        put_object = client.meta.service_model.operation_model("PutObject")
        self.assertIn("IfNoneMatch", put_object.input_shape.members)
        self.assertIn("ChecksumSHA256", put_object.input_shape.members)

    def test_artifact_record_round_trips_and_validates(self):
        record = ArtifactRecord(
            format="bike-map-stream-v1",
            media_type="application/vnd.openbikecomputer.map-stream",
            filename="map.bmap",
            object_key=(
                f"maps/map/bike-map-stream-v1/map-prod-1/{'5' * 64}/"
                f"{'1' * 64}/{'6' * 64}/{'4' * 64}.bmap"
            ),
            bytes=10,
            sha256="2" * 64,
            manifest_receipt="3" * 64,
            signed_manifest_receipt="4" * 64,
            signature_key_id="map-prod-1",
            signature_key_sha256="5" * 64,
            producer_build_sha256="1" * 64,
            producer_image_digest="sha256:" + "6" * 64,
        )
        self.assertEqual(ArtifactRecord.from_dict(record.to_dict()), record)
        for invalid_bytes in (True, 1 << 63, 10**100):
            malformed = record.to_dict()
            malformed["bytes"] = invalid_bytes
            with self.subTest(invalid_bytes=invalid_bytes), self.assertRaises(
                ValueError
            ):
                ArtifactRecord.from_dict(malformed)

        oversized_stream = record.to_dict()
        oversized_stream["bytes"] = MAXIMUM_STREAM_ARTIFACT_BYTES + 1
        with self.assertRaisesRegex(ValueError, "format limit"):
            ArtifactRecord.from_dict(oversized_stream)
        with self.assertRaises(ValueError):
            ArtifactRecord(
                format="x",
                media_type="x/y",
                filename="x",
                object_key="../escape",
                bytes=1,
                sha256="0" * 64,
            )

        with self.assertRaisesRegex(ValueError, "object key"):
            ArtifactRecord(
                format="bike-map-stream-v1",
                media_type="application/vnd.openbikecomputer.map-stream",
                filename="map.bmap",
                object_key=(
                    f"other/maps/map/bike-map-stream-v1/map-prod-1/{'5' * 64}/"
                    f"{'1' * 64}/{'6' * 64}/{'4' * 64}.bmap"
                ),
                bytes=10,
                sha256="2" * 64,
                manifest_receipt="3" * 64,
                signed_manifest_receipt="4" * 64,
                signature_key_id="map-prod-1",
                signature_key_sha256="5" * 64,
                producer_build_sha256="1" * 64,
                producer_image_digest="sha256:" + "6" * 64,
            )

    def test_filesystem_store_is_immutable_idempotent_and_race_safe(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.bmap"
            source.write_bytes(b"immutable-map-artifact")
            digest = sha256_file(source)
            store = FileSystemArtifactStore(root / "objects")
            key = f"maps/map/stream/{digest}.bmap"

            with ThreadPoolExecutor(max_workers=4) as executor:
                list(
                    executor.map(
                        lambda _: store.put(
                            source,
                            key,
                            sha256=digest,
                            media_type="application/octet-stream",
                        ),
                        range(8),
                    )
                )
            stored = store.local_path(key)
            self.assertIsNotNone(stored)
            self.assertEqual(stored.read_bytes(), source.read_bytes())
            self.assertIsNone(
                store.create_download_url(
                    key,
                    expires_in_seconds=60,
                    filename="map.bmap",
                    media_type="application/octet-stream",
                )
            )

            replacement = root / "replacement.bmap"
            replacement.write_bytes(b"different")
            with self.assertRaises(ArtifactStoreError):
                store.put(
                    replacement,
                    key,
                    sha256=sha256_file(replacement),
                    media_type="application/octet-stream",
                )
            self.assertTrue(store.delete(key))
            self.assertFalse(store.delete(key))

    def test_filesystem_store_wraps_source_io_with_stable_storage_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = FileSystemArtifactStore(Path(tmp) / "objects")
            with self.assertRaises(ArtifactStoreError) as raised:
                store.put(
                    Path(tmp) / "missing.bmap",
                    "maps/map/stream/missing.bmap",
                    sha256="0" * 64,
                    media_type="application/octet-stream",
                )
            self.assertEqual(raised.exception.code, "artifact_storage_failed")

    def test_s3_store_uses_conditional_put_metadata_and_presigned_get(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "map.bmap"
            source.write_bytes(b"s3-map-artifact")
            digest = sha256_file(source)
            client = FakeS3Client()
            client.conflicts_remaining = 1
            store = S3ArtifactStore(client, "bucket", prefix="prefix")
            key = f"maps/map/stream/{digest}.bmap"

            store.put(
                source,
                key,
                sha256=digest,
                media_type="application/vnd.openbikecomputer.map-stream",
            )
            store.put(
                source,
                key,
                sha256=digest,
                media_type="application/vnd.openbikecomputer.map-stream",
            )
            self.assertEqual(client.put_calls, 1)
            self.assertEqual(
                client.objects[("bucket", f"prefix/{key}")]["metadata"]["sha256"],
                digest,
            )
            url = store.create_download_url(
                key,
                expires_in_seconds=900,
                filename="Shanghai map.bmap",
                media_type="application/vnd.openbikecomputer.map-stream",
            )
            self.assertIn("prefix/maps/map/stream", url)
            self.assertIn("expires=900", url)
            self.assertTrue(store.delete(key))
            self.assertFalse(store.delete(key))

    def test_api_s3_factory_uses_separate_temporary_credentials(self):
        captured = {}

        def create_client(service, **options):
            captured["service"] = service
            captured["options"] = options
            return FakeS3Client()

        environment = {
            "MAP_PLATFORM_ARTIFACT_STORE": "s3",
            "MAP_PLATFORM_S3_BUCKET": "bucket",
            "MAP_PLATFORM_S3_API_ACCESS_KEY_ID": "api-read-key",
            "MAP_PLATFORM_S3_API_SECRET_ACCESS_KEY": "api-read-secret",
            "MAP_PLATFORM_S3_API_SESSION_TOKEN": "api-session-token",
            "AWS_REGION": "ap-southeast-1",
        }
        with patch.dict(os.environ, environment, clear=False), patch.dict(
            sys.modules,
            {"boto3": SimpleNamespace(client=create_client)},
        ):
            store = create_artifact_store_from_environment(
                "/unused",
                credential_scope="api",
            )

        self.assertIsInstance(store, S3ArtifactStore)
        self.assertEqual(captured["service"], "s3")
        self.assertEqual(captured["options"]["aws_access_key_id"], "api-read-key")
        self.assertEqual(captured["options"]["aws_secret_access_key"], "api-read-secret")
        self.assertEqual(captured["options"]["aws_session_token"], "api-session-token")

    def test_api_s3_factory_does_not_silently_inherit_worker_credentials(self):
        environment = {
            "MAP_PLATFORM_ARTIFACT_STORE": "s3",
            "MAP_PLATFORM_S3_BUCKET": "bucket",
            "MAP_PLATFORM_S3_API_ACCESS_KEY_ID": "",
            "MAP_PLATFORM_S3_API_SECRET_ACCESS_KEY": "",
            "MAP_PLATFORM_S3_API_SESSION_TOKEN": "",
            "MAP_PLATFORM_S3_API_USE_DEFAULT_CREDENTIAL_CHAIN": "0",
            "AWS_ACCESS_KEY_ID": "worker-write-key",
            "AWS_SECRET_ACCESS_KEY": "worker-write-secret",
        }
        with patch.dict(os.environ, environment, clear=False), patch.dict(
            sys.modules,
            {"boto3": SimpleNamespace(client=lambda *args, **kwargs: FakeS3Client())},
        ):
            with self.assertRaisesRegex(ValueError, "API S3 credentials"):
                create_artifact_store_from_environment(
                    "/unused",
                    credential_scope="api",
                )


if __name__ == "__main__":
    unittest.main()
