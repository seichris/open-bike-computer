import unittest

from map_platform.topography_notices import topography_attribution


class TopographyNoticeTests(unittest.TestCase):
    def test_both_pinned_sources_have_adapted_notices_and_liability_text(self):
        sample = {"sources": [
            {"sourceId": "copernicus-glo30-public-2021", "datasetRelease": "2021",
             "termsUrl": "https://example.test/glo30", "attributionUrl": "https://example.test/attribution"},
            {"sourceId": "copernicus-glo90-2021", "datasetRelease": "2021",
             "termsUrl": "https://example.test/glo90", "attributionUrl": "https://example.test/attribution"},
        ]}
        notice = topography_attribution(sample).decode("utf-8")
        for product in ("Copernicus WorldDEM-30", "Copernicus WorldDEM™-90"):
            self.assertIn(f"produced using {product} © DLR e.V.", notice)
            self.assertIn(f"do not incur any liability for any use of the {product}", notice)
        self.assertEqual(notice.count("Source notice: © DLR e.V."), 2)
        self.assertNotIn("not yet approved", notice)

    def test_unknown_source_or_release_cannot_get_a_public_notice(self):
        for source_id, release in (("other", "2021"),
                                   ("copernicus-glo30-public-2021", "2024")):
            with self.subTest(source_id=source_id, release=release):
                with self.assertRaisesRegex(ValueError, "no reviewed public notice"):
                    topography_attribution({"sources": [{"sourceId": source_id,
                                                          "datasetRelease": release}]})


if __name__ == "__main__":
    unittest.main()
