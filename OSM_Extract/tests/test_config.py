import pathlib
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]


class OSMConfigTests(unittest.TestCase):
    def test_extract_config_parses_and_has_expected_tags(self):
        config = yaml.safe_load((ROOT / "conf" / "conf_extract.yaml").read_text())

        self.assertIn("natural", config["lines"]["tags"])
        self.assertNotIn("natural]", config["lines"]["tags"])
        highway_types = config["lines"]["feature_types"]["highway"]
        self.assertIn("tertiary", highway_types)
        self.assertEqual(list(highway_types.keys()).count("tertiary"), 1)

    def test_style_configs_parse(self):
        for path in [
            ROOT / "conf" / "conf_styles.yaml",
            ROOT / "conf" / "conf_styles_apple.yaml",
        ]:
            with self.subTest(path=path.name):
                self.assertIsInstance(yaml.safe_load(path.read_text()), dict)


if __name__ == "__main__":
    unittest.main()
