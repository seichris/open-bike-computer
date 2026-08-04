from pathlib import Path
import re
import unittest


ESP32_ROOT = Path(__file__).resolve().parents[2]
MAIN_SCREEN_SOURCE = (
    ESP32_ROOT / "lib" / "gui" / "src" / "mainScr.cpp"
).read_text(encoding="utf-8")
MAP_RENDERER_SOURCE = (
    ESP32_ROOT / "lib" / "maps" / "src" / "maps.cpp"
).read_text(encoding="utf-8")


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index]
    raise AssertionError(f"unterminated function: {signature}")


class MapGuidanceIntegrationTests(unittest.TestCase):
    def test_birds_eye_activation_does_not_require_a_route(self):
        match = re.search(
            r"const bool birdsEyeActive\s*=\s*(.*?);",
            function_body(MAP_RENDERER_SOURCE, "bool Maps::generateVectorMap"),
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        expression = match.group(1)
        self.assertIn("usesMapGuidanceBirdsEye", expression)
        self.assertIn("isMapGuidanceScreenActive()", expression)
        self.assertIn("mapNavigationBirdsEyeEnabled", expression)
        self.assertNotIn("hasRoute", expression)

    def test_map_guidance_owns_no_destination_picker(self):
        self.assertNotIn("mapGuidanceDestinationPicker", MAIN_SCREEN_SOURCE)
        overlay_body = function_body(
            MAIN_SCREEN_SOURCE, "static void createMapGuidanceOverlay"
        )
        self.assertNotIn("createDestinationPickerContainer", overlay_body)
        self.assertIn("mapGuidanceArrow =", overlay_body)
        self.assertIn("mapGuidanceDistance =", overlay_body)

    def test_map_guidance_overlay_is_navigation_data_gated(self):
        update_body = function_body(
            MAIN_SCREEN_SOURCE, "static void updateMapGuidanceOverlay() {"
        )
        reveal_body = function_body(
            MAIN_SCREEN_SOURCE, "static void revealPendingMapTileIfReady() {"
        )
        self.assertIn(
            "if (navigation_content_mode::hidesMapGuidanceOverlay("
            "hasNavigationData))",
            update_body,
        )
        self.assertIn(
            "navigation_content_mode::showsMapGuidanceOverlay(\n"
            "          hasCurrentNavigationData())",
            reveal_body,
        )
        self.assertIn("setHiddenIfChanged(mapGuidanceOverlay, true)", update_body)

    def test_building_extrusion_uses_complete_map_guidance_gate(self):
        match = re.search(
            r"bool extrudeBuildings\s*=\s*(.*?);",
            MAP_RENDERER_SOURCE,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        expression = match.group(1)
        self.assertIn("extrudesMapGuidanceBuildings", expression)
        self.assertIn("buildingsVisible", expression)
        self.assertIn("mapNavigationActive", expression)
        self.assertIn("projection.isBirdsEye()", expression)
        self.assertIn("mapNavigation3DBuildingsEnabled", expression)
        self.assertNotIn("hasRoute", expression)

    def test_navigation_screen_retains_destination_picker(self):
        create_body = function_body(MAIN_SCREEN_SOURCE, "void createMainScr")
        update_body = function_body(MAIN_SCREEN_SOURCE, "void updateNavEvent")
        self.assertIn(
            "createDestinationPickerContainer(navTile)", create_body
        )
        self.assertIn(
            "renderDestinationPicker(navigationDestinationPicker)", update_body
        )


if __name__ == "__main__":
    unittest.main()
