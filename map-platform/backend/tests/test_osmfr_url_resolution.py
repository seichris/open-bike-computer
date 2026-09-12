"""Pure resolver tests; all networking remains in SourceCache."""
import re
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from map_platform.osmfr_fallback import (
    ALIASES, EXCEPTIONS, GEOFABRIK_BASE, OSMFR_BASE, fallback_url,
)

SUFFIX = "-latest.osm.pbf"


def region(path="asia/china/shanghai", **overrides):
    return SimpleNamespace(**{
        "url": GEOFABRIK_BASE + path + SUFFIX,
        "provider": "geofabrik", "checksum": None, "published_at": None,
        **overrides,
    })


class OsmfrUrlResolutionTests(unittest.TestCase):
    def test_same_paths_need_no_catalogue_entry(self):
        for path in (
            "asia/china/shanghai", "asia/china/jiangsu", "asia/china/zhejiang",
            "asia/china/tibet", "asia/china/macau", "asia/japan/kanto",
            "europe/germany", "south-america/brazil", "africa/kenya",
            "asia/future-region/subregion_2", "asia/taiwan", "south-america",
        ):
            with self.subTest(path=path):
                self.assertNotIn(path, ALIASES)
                self.assertNotIn(path, EXCEPTIONS)
                self.assertEqual(fallback_url(region(path)), OSMFR_BASE + path + SUFFIX)

    def test_construction_is_pure_and_does_not_mutate_source(self):
        source = region()
        before = vars(source).copy()
        with patch("urllib.request.urlopen", side_effect=AssertionError("unexpected network")):
            self.assertEqual(fallback_url(source), OSMFR_BASE + "asia/china/shanghai" + SUFFIX)
        self.assertEqual(vars(source), before)

    def test_actual_chinese_catalogue_names(self):
        self.assertEqual(fallback_url(region("asia/china/inner-mongolia")),
                         OSMFR_BASE + "asia/china/inner_mongolia" + SUFFIX)
        self.assertEqual(fallback_url(region("asia/china/hong-kong")),
                         OSMFR_BASE + "asia/china/hong_kong" + SUFFIX)
        for name in ("xizang", "neimenggu"):
            self.assertNotIn("asia/china/" + name, ALIASES)

    def test_similarly_named_chinese_provinces_stay_distinct(self):
        for name in ("shanxi", "shaanxi"):
            self.assertEqual(fallback_url(region("asia/china/" + name)),
                             OSMFR_BASE + "asia/china/" + name + SUFFIX)

    def test_country_and_us_state_georgia_are_not_confused(self):
        self.assertEqual(fallback_url(region("europe/georgia")), OSMFR_BASE + "asia/georgia" + SUFFIX)
        self.assertEqual(fallback_url(region("north-america/us/georgia")),
                         OSMFR_BASE + "north-america/us-south/georgia" + SUFFIX)

    def test_american_paths_keep_their_real_punctuation(self):
        self.assertEqual(fallback_url(region("north-america/us/new-york")),
                         OSMFR_BASE + "north-america/us-northeast/new-york" + SUFFIX)
        self.assertEqual(fallback_url(region("north-america/canada/new-brunswick")),
                         OSMFR_BASE + "north-america/canada/new_brunswick" + SUFFIX)

    def test_fiji_uses_the_merged_extract_not_one_dateline_half(self):
        self.assertEqual(fallback_url(region("australia-oceania/fiji")), OSMFR_BASE + "merge/fiji" + SUFFIX)

    def test_falklands_use_the_actual_catalogue_path(self):
        self.assertEqual(fallback_url(region("europe/united-kingdom/falklands")),
                         OSMFR_BASE + "south-america/falkland" + SUFFIX)

    def test_combined_israel_palestine_is_not_reduced_to_one_component(self):
        self.assertEqual(fallback_url(region("asia/israel-and-palestine")),
                         OSMFR_BASE + "asia/israel_and_palestine" + SUFFIX)

    def test_russian_district_names_are_explicit(self):
        self.assertEqual(fallback_url(region("russia/north-caucasus-fed-district")),
                         OSMFR_BASE + "russia/north_caucasian_federal_district" + SUFFIX)
        self.assertEqual(fallback_url(region("russia/south-fed-district")),
                         OSMFR_BASE + "russia/southern_federal_district" + SUFFIX)

    def test_table_contains_only_differences_and_safe_paths(self):
        safe_path = re.compile(r"[a-z0-9][a-z0-9_-]*(?:/[a-z0-9][a-z0-9_-]*)*")
        self.assertFalse(ALIASES.keys() & EXCEPTIONS.keys())
        for source, destination in ALIASES.items():
            with self.subTest(source=source):
                self.assertNotEqual(source, destination)
                self.assertIsNotNone(safe_path.fullmatch(source))
                self.assertIsNotNone(safe_path.fullmatch(destination))
                self.assertEqual(fallback_url(region(source)), OSMFR_BASE + destination + SUFFIX)

    def test_every_exception_has_a_reason_and_is_not_attempted(self):
        for path, reason in EXCEPTIONS.items():
            with self.subTest(path=path):
                self.assertTrue(reason.strip())
                self.assertIsNone(fallback_url(region(path)))

    def test_scope_exceptions_do_not_blacklist_safe_children(self):
        # Indonesia's parent includes East Timor; an independently requested
        # child is not replaced by the parent, nor rejected solely for its prefix.
        self.assertIsNone(fallback_url(region("asia/indonesia")))
        self.assertEqual(fallback_url(region("asia/indonesia/bali")),
                         OSMFR_BASE + "asia/indonesia/bali" + SUFFIX)
        self.assertIsNone(fallback_url(region("north-america/us")))
        self.assertIsNotNone(fallback_url(region("north-america/us/california")))

    def test_aliases_do_not_guess_child_paths_or_widen_to_parents(self):
        for path in ("north-america/us/california/socal", "europe/united-kingdom/england/london",
                     "europe/germany/nordrhein-westfalen/arnsberg-regbez"):
            self.assertEqual(fallback_url(region(path)), OSMFR_BASE + path + SUFFIX)

    def test_no_global_hyphen_replacement_or_basename_matching(self):
        for path in ("asia/unknown-region", "europe/new-york", "asia/inner-mongolia"):
            self.assertEqual(fallback_url(region(path)), OSMFR_BASE + path + SUFFIX)

    def test_pinned_and_non_geofabrik_sources_do_not_switch(self):
        for changes in ({"provider": "custom"}, {"provider": "osmfr"},
                        {"checksum": "a" * 64}, {"published_at": "2026-09-06T00:00:00Z"}):
            with self.subTest(changes=changes):
                self.assertIsNone(fallback_url(region(**changes)))

    def test_only_canonical_https_public_host_is_accepted(self):
        tail = "asia/china/shanghai" + SUFFIX
        for base in (
            "http://download.geofabrik.de/", "https://download.geofabrik.de:443/",
            "https://user:pass@download.geofabrik.de/", "https://download.geofabrik.de.evil/",
            "https://download.geofabrik.de@evil/", "https://download.geofabrik.de./",
            "https://osm-internal.download.geofabrik.de/", "https://example.org/",
            "//download.geofabrik.de/", "https://DOWNLOAD.GEOFABRIK.DE/",
        ):
            with self.subTest(base=base):
                self.assertIsNone(fallback_url(region(url=base + tail)))

    def test_queries_fragments_controls_and_encoded_paths_are_rejected(self):
        url = region().url
        bad_urls = [url + tail for tail in ("?", "?token=x", "#", "#fragment", "/", "\n", "\r\n", " ")]
        bad_urls += [" " + url, "\t" + url, url.replace("shanghai", "shan\tghai"),
                     url.replace("shanghai", "%73hanghai"), url.replace("/china/", "/%2e%2e/"),
                     url.replace("/china/", "/china%2f"), url.replace("/china/", "//china/"),
                     url.replace("/china/", "/../china/"), url.replace("/china/", "/./china/"),
                     url.replace("/china/", "\\china\\"), url.replace("shanghai", "上海"),
                     url.replace("shanghai", "shanghai;extra"), None, b"not-a-text-url"]
        for value in bad_urls:
            with self.subTest(url=value):
                self.assertIsNone(fallback_url(region(url=value)))

    def test_dated_other_formats_and_empty_paths_are_rejected(self):
        for tail in ("asia/china/shanghai-260905.osm.pbf", "asia/china/shanghai.osm.pbf",
                     "asia/china/shanghai-latest-free.shp.zip", "-latest.osm.pbf",
                     "/-latest.osm.pbf", "asia/china/-latest.osm.pbf", "asia/china/.osm.pbf"):
            with self.subTest(tail=tail):
                self.assertIsNone(fallback_url(region(url=GEOFABRIK_BASE + tail)))

    def test_research_document_covers_the_runtime_tables(self):
        document = (Path(__file__).resolve().parents[3] / "docs/osmfr-alias-research.md").read_text()
        for source, destination in ALIASES.items():
            self.assertIn(f"| `{source}` | `{destination}` |", document)
        for source in EXCEPTIONS:
            self.assertIn(f"| `{source}` |", document)


if __name__ == "__main__":
    unittest.main()
