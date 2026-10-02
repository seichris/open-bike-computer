from __future__ import annotations

import copy
import hashlib
import unittest
from unittest.mock import patch

from map_platform.topography_discovery import REGIONAL_SOURCES, discover_regional, _allowed_url, _checksum
from map_platform.topography_pipeline import canonical_bytes


def feature(source_id, item_id="tile-1"):
    source = REGIONAL_SOURCES[source_id]
    if source_id == "swissalti3d-2m":
        key = "tile-1_2_2056_5728.tif"
        asset = {"href": source.asset_prefixes[0] + key, "type": "image/tiff", "eo:gsd": 2, "proj:epsg": 2056}
    else:
        key = "dtm" if source_id == "canada-hrdem-lidar" else "visual"
        asset = {"href": source.asset_prefixes[0] + item_id + "-dtm.tif", "type": "image/tiff"}
    asset["file:checksum"] = "1220" + "A" * 64
    return {"type": "Feature", "collection": source.collection_id or "linz-edition-id", "id": item_id,
            "bbox": [6, 45, 7, 46], "geometry": {"type": "Polygon", "coordinates": [[[6, 45], [7, 45], [7, 46], [6, 46], [6, 45]]]},
            "properties": {"datetime": "2025-01-01T00:00:00Z", "proj:epsg": 2056},
            "assets": {key: asset, "thumbnail": {"href": "https://example.invalid/thumb.png", "type": "image/png"}}}


class RegionalDiscoveryTests(unittest.TestCase):
    def run_discovery(self, source_id="swissalti3d-2m", *, mutate=lambda docs: None):
        source = REGIONAL_SOURCES[source_id]
        first = feature(source_id)
        collection = {"id": first["collection"], "license": "proprietary", "links": []}
        if source.static:
            collection["links"] = [{"rel": "item", "href": "./tile.json", "file:checksum": "1220" + hashlib.sha256(canonical_bytes(first)).hexdigest()}]
            docs = [collection, first]
        else:
            docs = [collection, {"type": "FeatureCollection", "features": [first], "links": []}]
        mutate(docs)
        raw = [canonical_bytes(document) for document in docs]
        calls = []

        def fetch(url, cancel, deadline):
            calls.append(url)
            return raw[len(calls) - 1]

        result = discover_regional(source_id, [6.1, 45.1, 6.2, 45.2], fetch=fetch)
        self.assertEqual([doc["utf8"].encode() for doc in result["documents"]], raw)
        return result, calls

    def test_each_adapter_preserves_metadata_and_native_checksums(self):
        for source_id in REGIONAL_SOURCES:
            with self.subTest(source=source_id):
                result, calls = self.run_discovery(source_id)
                self.assertEqual(len(result["assets"]), 1)
                self.assertEqual(result["assets"][0]["providerSha256"], "a" * 64)
                self.assertIsNone(result["assets"][0]["verticalDatum"])
                self.assertFalse(result["productionEligible"])
                self.assertFalse(result["validPixelCoverageVerified"])
                self.assertEqual(len(calls), 2)

    def test_pagination_follows_returned_links_without_losing_filters(self):
        source = REGIONAL_SOURCES["swissalti3d-2m"]
        next_url = source.collection_url + "/items?cursor=opaque&bbox=6,45,7,46"

        def pages(docs):
            docs[1]["links"] = [{"rel": "next", "href": next_url}]
            docs.append({"type": "FeatureCollection", "features": [feature("swissalti3d-2m", "tile-2")], "links": []})

        result, calls = self.run_discovery(mutate=pages)
        self.assertEqual(calls[-1], next_url)
        self.assertEqual(len(result["assets"]), 2)

    def test_failures_never_return_partial_success(self):
        mutations = [
            lambda d: d[1]["links"].append({"rel": "next", "href": "https://evil.invalid/page"}),
            lambda d: d[1]["links"].append({"rel": "next", "href": REGIONAL_SOURCES["swissalti3d-2m"].collection_url}),
            lambda d: d[1]["links"].append({"rel": "next", "href": "./next", "method": "POST"}),
            lambda d: d[1]["features"].append(copy.deepcopy(d[1]["features"][0])),
            lambda d: d[1]["features"][0].update(collection="some-dsm-collection"),
            lambda d: d[1]["features"][0]["assets"].pop("tile-1_2_2056_5728.tif"),
            lambda d: d[1]["features"][0]["assets"]["tile-1_2_2056_5728.tif"].update(href="http://localhost/file.tif"),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                self.run_discovery(mutate=mutate)
        with patch("map_platform.topography_discovery.MAX_DOCUMENTS", 1), self.assertRaisesRegex(ValueError, "incomplete"):
            self.run_discovery()
        with patch("map_platform.topography_discovery.MAX_DOCUMENT_BYTES", 10), self.assertRaisesRegex(ValueError, "byte budget"):
            self.run_discovery()

    def test_linz_provider_metadata_checksum_is_verified(self):
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.run_discovery("linz-national-dem-1m", mutate=lambda d: d[1].update(id="tampered"))

    def test_canadian_asset_key_does_not_override_a_dsm_product_url(self):
        def mutate(docs):
            asset = docs[1]["features"][0]["assets"]["dtm"]
            asset["href"] = asset["href"].replace("-dtm.tif", "-dsm.tif")
        with self.assertRaisesRegex(ValueError, "suffix disagree"):
            self.run_discovery("canada-hrdem-lidar", mutate=mutate)

    def test_cancelled_discovery_returns_no_snapshot(self):
        with self.assertRaises(InterruptedError):
            discover_regional("swissalti3d-2m", [6, 45, 7, 46],
                              cancel=lambda: (_ for _ in ()).throw(InterruptedError("cancelled")),
                              fetch=lambda *a: self.fail("cancelled discovery must not fetch"))

    def test_network_and_auth_failures_are_not_source_fallback(self):
        for error in (TimeoutError("timeout"), PermissionError("not authorized")):
            with self.subTest(error=error), self.assertRaises(type(error)):
                discover_regional("swissalti3d-2m", [6, 45, 7, 46], fetch=lambda *a: (_ for _ in ()).throw(error))

    def test_host_paths_and_checksums_fail_closed(self):
        prefix = ("https://data.geo.admin.ch/ch.swisstopo.swissalti3d/",)
        for value in ("https://data.geo.admin.ch.evil/ch.swisstopo.swissalti3d/a.tif",
                      prefix[0] + "../a.tif", prefix[0] + "%2e%2e/a.tif", prefix[0] + "a.tif#fragment",
                      "https://user:secret@data.geo.admin.ch/ch.swisstopo.swissalti3d/a.tif"):
            with self.assertRaises(ValueError):
                _allowed_url(value, prefix)
        for value in ("a" * 64, "1220" + "x" * 64, True):
            with self.assertRaises(ValueError):
                _checksum({"file:checksum": value})
        with self.assertRaisesRegex(ValueError, "conflicting"):
            _checksum({"file:checksum": "1220" + "a" * 64, "checksum:multihash": "1220" + "b" * 64})


if __name__ == "__main__":
    unittest.main()
