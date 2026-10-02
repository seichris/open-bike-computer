from __future__ import annotations

import os
import unittest
from unittest.mock import patch

from map_platform.artifacts import ArtifactStoreError
from map_platform.preparation_objects import (
    PreparationObjectStore, create_preparation_store_from_environment,
)
from tests.test_artifacts import FakeS3Client, FakeS3Error


class PreparationObjectStoreTests(unittest.TestCase):
    def test_document_is_immutable_canonical_and_integrity_checked(self):
        client = FakeS3Client()
        store = PreparationObjectStore(client, "preparation-test")
        slot = "a" * 64
        document = {"sourceId": "dem", "tileSha256": "b" * 64}
        self.assertIsNone(store.read_document("dem-receipt", slot))
        store.publish_document("dem-receipt", slot, document)
        store.publish_document("dem-receipt", slot, document)
        self.assertEqual(store.read_document("dem-receipt", slot), document)
        with self.assertRaises(ArtifactStoreError):
            store.publish_document("dem-receipt", slot, {**document, "tileSha256": "c" * 64})
        key = ("preparation-test", f"map-preparation-v1/dem-receipt/documents/{slot}")
        body = client.objects[key]["body"]
        client.objects[key]["body"] = body.replace(b"dem", b"bad")
        with self.assertRaises(ArtifactStoreError):
            store.read_document("dem-receipt", slot)

    def test_configuration_is_worker_only_and_requires_contabo_https(self):
        with patch.dict(os.environ, {"MAP_PLATFORM_PREPARATION_STORE": "disabled"}):
            self.assertIsNone(create_preparation_store_from_environment())
        fields = {
            "MAP_PLATFORM_PREPARATION_STORE": "contabo-s3",
            "MAP_PLATFORM_PREPARATION_S3_BUCKET": "test-bucket",
            "MAP_PLATFORM_PREPARATION_S3_ACCESS_KEY_ID": "test-access",
            "MAP_PLATFORM_PREPARATION_S3_SECRET_ACCESS_KEY": "test-secret",
        }
        for endpoint in ("http://eu2.contabostorage.com", "https://evil.example",
                         "https://eu2.contabostorage.com/path", "https://user:pass@eu2.contabostorage.com"):
            with self.subTest(endpoint=endpoint), patch.dict(os.environ, {
                **fields, "MAP_PLATFORM_PREPARATION_S3_ENDPOINT_URL": endpoint,
            }):
                with self.assertRaisesRegex(ValueError, "Contabo HTTPS"):
                    create_preparation_store_from_environment()

    def test_document_read_does_not_treat_storage_failure_as_cache_miss(self):
        client = FakeS3Client()
        client.get_object = lambda **_kwargs: (_ for _ in ()).throw(FakeS3Error(503, "ServiceUnavailable"))
        store = PreparationObjectStore(client, "preparation-test")
        with self.assertRaisesRegex(ArtifactStoreError, "failed to read"):
            store.read_document("dem-receipt", "a" * 64)
