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
LVGL_SETUP_SOURCE = (
    ESP32_ROOT / "lib" / "lvgl" / "src" / "lvglSetup.cpp"
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

    def test_dense_scene_selection_uses_shared_nearest_first_policy(self):
        render_body = function_body(MAP_RENDERER_SOURCE, "bool Maps::readVectorMap")
        self.assertIn(
            "map_building_renderer::selectNearestForExtrusion(\n"
            "                    buildingQueue.rbegin(), buildingQueue.rend(),\n"
            "                    shouldStopBuildingWork)",
            render_body,
        )
        self.assertIn("item.extrude", render_body)
        self.assertIn("buildingSelection.flatOverflow()", render_body)
        self.assertIn("buildingSelection.recordLimitOverflow", render_body)
        self.assertIn("buildingSelection.pointLimitOverflow", render_body)

    def test_total_building_work_is_bounded_before_surface_rendering(self):
        render_body = function_body(MAP_RENDERER_SOURCE, "bool Maps::readVectorMap")
        self.assertIn(
            "buildingRecords=%u buildingRings=%u", MAP_RENDERER_SOURCE
        )
        self.assertIn(
            "buildingPoints=%u heightExplicit=%u", MAP_RENDERER_SOURCE
        )
        self.assertIn("kMaximumRenderedBuildingPointsPerRecord", render_body)
        self.assertIn("kMaximumRenderedBuildingRecords", render_body)
        self.assertIn("retainNearestCandidate", render_body)
        self.assertIn("selectNearestForRendering", render_body)
        self.assertIn("kMaximumBuildingRenderTimeMs", render_body)
        self.assertLess(
            render_body.index("const uint32_t buildingPassStartMs"),
            render_body.index("for (MapBlock *block : memCache.blocks)"),
        )
        self.assertIn("projectedFootprintAreaPixels", render_body)
        self.assertIn("if (mayExtrude && extrusionZoomEligible)", render_body)
        self.assertIn("shouldStopBuildingWork", render_body)
        self.assertIn("eligibleExtrusionZoom(zoom)", render_body)
        self.assertIn("deadlineExceeded=%u", render_body)
        self.assertIn("prepassDeadlineExceeded=%u", render_body)
        self.assertIn("wallCandidates=%llu", render_body)
        self.assertIn("generatedWallFaces=%llu", render_body)
        self.assertIn("suppressedWallFaces=%llu", render_body)
        self.assertIn("parsedRecords=%u parsedRings=%u", render_body)
        self.assertIn("parsedPoints=%u heightExplicit=%u", render_body)
        self.assertIn("heightClassDefault=%u", render_body)
        self.assertIn("psramLargest=%u", render_body)
        self.assertIn("if (!item.render)", render_body)

    def test_ground_roads_render_once_before_buildings(self):
        render_body = function_body(MAP_RENDERER_SOURCE, "bool Maps::readVectorMap")
        self.assertEqual(render_body.count("for (const auto &line :"), 1)
        self.assertLess(
            render_body.index("////// Lines"),
            render_body.index(
                "buildingPassPhase = BuildingPassPhase::Draw;"
            ),
        )
        self.assertNotIn(
            "roads once above them",
            render_body,
        )

    def test_navigation_route_remains_above_completed_map(self):
        render_body = function_body(MAP_RENDERER_SOURCE, "bool Maps::generateVectorMap")
        self.assertLess(
            render_body.index("Maps::readVectorMap("),
            render_body.index("routeOverlay.drawRoute("),
        )

    def test_building_deadline_and_allocation_failures_discard_scratch_frame(self):
        render_body = function_body(MAP_RENDERER_SOURCE, "bool Maps::readVectorMap")
        self.assertIn("runAllocationSafe", render_body)
        self.assertIn("buildingAllocationFailed", render_body)
        self.assertIn("buildingDeadlineAborted", render_body)
        self.assertIn('reason=%s', render_body)
        self.assertIn('"allocation"', render_body)
        self.assertIn('"deadline"', render_body)
        self.assertIn('fallback=buildings-hidden', render_body)
        self.assertIn("renderTimeOverflowTotal=%llu", render_body)
        self.assertIn("projectionMs=%lu sortMs=%lu buildingDrawMs=%lu", render_body)
        self.assertIn("psramUsed=%u psramFree=%u", render_body)
        self.assertIn("shouldRetryWithoutBuildings", render_body)
        self.assertIn("buildingFailureRetryCooldown.recordFailure", render_body)
        self.assertIn("psramSamplePostCleanup", render_body)
        self.assertGreaterEqual(render_body.count("releaseBuildingFailureWorkspace();"), 2)
        self.assertLess(
            render_body.rindex("releaseBuildingFailureWorkspace();"),
            render_body.index("drawStreetLabels"),
        )
        self.assertIn(
            "projection, drawLabels, true)",
            render_body,
        )
        self.assertRegex(
            render_body,
            r"if \(!buildingPassCompleted\)\s*\{[\s\S]*?return false;\s*\}",
        )

    def test_navigation_screen_retains_destination_picker(self):
        create_body = function_body(MAIN_SCREEN_SOURCE, "void createMainScr")
        update_body = function_body(MAIN_SCREEN_SOURCE, "void updateNavEvent")
        self.assertIn(
            "createDestinationPickerContainer(navTile)", create_body
        )
        self.assertIn(
            "renderDestinationPicker(navigationDestinationPicker)", update_body
        )

    def test_main_screen_entry_defers_first_render_to_configured_screen(self):
        load_body = function_body(LVGL_SETUP_SOURCE, "void loadMainScreen")
        self.assertEqual(load_body.count("main_screen_entry_policy::enter("), 1)
        self.assertEqual(load_body.count("showConfiguredDefaultMainScreen()"), 1)
        self.assertNotIn("generateVectorMap", load_body)
        self.assertNotIn("generateRenderMap", load_body)
        self.assertNotIn("displayMap", load_body)
        self.assertNotRegex(load_body, r"\bzoom\s*=\s*\d+")


if __name__ == "__main__":
    unittest.main()
