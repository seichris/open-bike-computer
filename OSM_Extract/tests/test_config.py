import pathlib
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def construct_mapping_without_duplicate_keys(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key ({key})",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    construct_mapping_without_duplicate_keys,
)


def load_yaml_unique(path):
    return yaml.load(path.read_text(), Loader=UniqueKeyLoader)


class OSMConfigTests(unittest.TestCase):
    def test_extract_config_parses_and_has_expected_tags(self):
        config = load_yaml_unique(ROOT / "conf" / "conf_extract.yaml")

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
                self.assertIsInstance(load_yaml_unique(path), dict)


if __name__ == "__main__":
    unittest.main()
