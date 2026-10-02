"""Additional researched alias regressions; no live downloads are performed."""
import ast
import inspect
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from map_platform import osmfr_fallback as fallback

GEO = "https://download.geofabrik.de/"
FR = "https://download.openstreetmap.fr/extracts/"
SUFFIX = "-latest.osm.pbf"


class AdditionalOsmfrAliasesTests(unittest.TestCase):
    def resolve(self, path, **overrides):
        return fallback.fallback_url(SimpleNamespace(**{
            "url": GEO + path + SUFFIX,
            "provider": "geofabrik", "checksum": None, "published_at": None,
            **overrides,
        }))

    def test_french_region_spelling(self):
        self.assertEqual(self.resolve("europe/france/ile-de-france"),
                         FR + "europe/france/ile_de_france" + SUFFIX)
        self.assertEqual(self.resolve("europe/france/provence-alpes-cote-d-azur"),
                         FR + "europe/france/provence_alpes_cote_d_azur" + SUFFIX)

    def test_overseas_regions_move_without_basename_matching(self):
        cases = {
            "europe/france/guyane": "south-america/guyane",
            "europe/france/reunion": "africa/reunion",
            "europe/france/guadeloupe": "central-america/guadeloupe",
            "europe/united-kingdom/bermuda": "north-america/bermuda",
            "north-america/us/puerto-rico": "central-america/puerto_rico",
        }
        for source, target in cases.items():
            with self.subTest(source=source):
                self.assertEqual(self.resolve(source), FR + target + SUFFIX)
        self.assertEqual(self.resolve("south-america/guyana"), FR + "south-america/guyana" + SUFFIX)

    def test_australian_abbreviation_and_literal_provider_typo(self):
        self.assertEqual(self.resolve("australia-oceania/australia/act"),
                         FR + "oceania/australia/australian_capital_territory" + SUFFIX)
        self.assertEqual(self.resolve("australia-oceania/australia/heard-mcdonald"),
                         FR + "oceania/australia/heard_island_and_mcdonald_slands" + SUFFIX)

    def test_kiribati_uses_provider_merge(self):
        self.assertEqual(self.resolve("australia-oceania/kiribati"), FR + "merge/kiribati" + SUFFIX)

    def test_additional_african_aliases(self):
        cases = {
            "africa/comores": "africa/comoros",
            "africa/cape-verde": "africa/cape_verde",
            "africa/central-african-republic": "africa/central_african_republic",
            "africa/sao-tome-and-principe": "africa/sao_tome_and_principe",
        }
        for source, target in cases.items():
            with self.subTest(source=source):
                self.assertEqual(self.resolve(source), FR + target + SUFFIX)

    def test_greater_london_is_exact_not_a_subtree_rewrite(self):
        self.assertEqual(self.resolve("europe/united-kingdom/england/greater-london"),
                         FR + "europe/united_kingdom/england/greater_london" + SUFFIX)
        path = "europe/united-kingdom/england/greater-london/new-borough"
        self.assertEqual(self.resolve(path), FR + path + SUFFIX)

    def test_new_scope_holds_and_independent_children(self):
        for path in ("asia/china/guangdong", "asia/china/hebei", "europe/guernsey-jersey"):
            with self.subTest(path=path):
                self.assertIsNone(self.resolve(path))
        self.assertEqual(self.resolve("asia/china/hong-kong"), FR + "asia/china/hong_kong" + SUFFIX)
        self.assertEqual(self.resolve("asia/china/beijing"), FR + "asia/china/beijing" + SUFFIX)
        self.assertEqual(self.resolve("asia/china/hebei/new-child"), FR + "asia/china/hebei/new-child" + SUFFIX)

    def test_unverified_names_still_probe_only_the_literal_same_path(self):
        for path in ("asia/taiwan", "south-america", "asia/china/xizang",
                     "asia/china/neimenggu", "europe/new-region"):
            with self.subTest(path=path):
                self.assertEqual(self.resolve(path), FR + path + SUFFIX)

    def test_no_network_or_pinned_provider_switch(self):
        with patch("urllib.request.urlopen", side_effect=AssertionError("unexpected HTTP")):
            self.assertIsNotNone(self.resolve("australia-oceania/australia/act"))
            self.assertIsNone(self.resolve("australia-oceania/australia/act", checksum="a" * 64))
            self.assertIsNone(self.resolve("australia-oceania/australia/act", published_at="2026-09-06T00:00:00Z"))
            self.assertIsNone(self.resolve("australia-oceania/australia/act", provider="custom"))

    def test_all_rules_are_documented_and_have_no_duplicate_literal_keys(self):
        doc = (Path(__file__).resolve().parents[3] / "docs/osmfr-alias-research.md").read_text()
        for source, target in fallback.ALIASES.items():
            self.assertIn(f"| `{source}` | `{target}` |", doc)
            self.assertEqual(self.resolve(source), FR + target + SUFFIX)
        for source, reason in fallback.EXCEPTIONS.items():
            self.assertIn(f"| `{source}` |", doc)
            self.assertTrue(reason.strip())
            self.assertIsNone(self.resolve(source))
        tree = ast.parse(inspect.getsource(fallback))
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in {"ALIASES", "EXCEPTIONS"} for t in node.targets):
                keys = [ast.literal_eval(k) for k in node.value.keys]
                self.assertEqual(len(keys), len(set(keys)))


if __name__ == "__main__":
    unittest.main()
