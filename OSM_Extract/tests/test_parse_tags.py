import importlib.util
import pathlib
import sys
import types
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_funcs_module():
    shapely = types.ModuleType("shapely")
    for name in [
        "geometry",
        "LineString",
        "LinearRing",
        "Polygon",
        "MultiPolygon",
        "MultiLineString",
        "Point",
    ]:
        setattr(shapely, name, object)
    shapely.intersection = lambda *args, **kwargs: None

    shapely_ops = types.ModuleType("shapely.ops")
    shapely_ops.triangulate = lambda *args, **kwargs: []

    pil = types.ModuleType("PIL")
    pil_image_draw = types.ModuleType("PIL.ImageDraw")
    pil_image = types.ModuleType("PIL.Image")

    original_modules = {}
    for name, module in [
        ("shapely", shapely),
        ("shapely.ops", shapely_ops),
        ("PIL", pil),
        ("PIL.ImageDraw", pil_image_draw),
        ("PIL.Image", pil_image),
    ]:
        original_modules[name] = sys.modules.get(name)
        sys.modules[name] = module

    try:
        spec = importlib.util.spec_from_file_location("osm_funcs", ROOT / "scripts" / "funcs.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        for name, original in original_modules.items():
            if original is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = original


class ParseTagsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.funcs = load_funcs_module()

    def test_parse_tags_extracts_valid_pairs(self):
        tags = self.funcs.parse_tags('"highway"=>"primary","name"=>"Main St"')

        self.assertEqual(tags["highway"], "primary")
        self.assertEqual(tags["name"], "Main St")

    def test_parse_tags_skips_malformed_pairs(self):
        tags = self.funcs.parse_tags('"highway"=>"primary","badtag",""=>"empty","name"=>"Main St"')

        self.assertEqual(tags["highway"], "primary")
        self.assertEqual(tags["name"], "Main St")
        self.assertNotIn("badtag", tags)
        self.assertNotIn("", tags)

    def test_parse_tags_accepts_empty_or_non_string_values(self):
        self.assertEqual(self.funcs.parse_tags(""), {})
        self.assertEqual(self.funcs.parse_tags(None), {})


if __name__ == "__main__":
    unittest.main()
