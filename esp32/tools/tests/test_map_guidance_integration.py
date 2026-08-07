from pathlib import Path
import unittest


ESP32_ROOT = Path(__file__).resolve().parents[2]
MAIN_SCREEN_SOURCE = (
    ESP32_ROOT / "lib" / "gui" / "src" / "mainScr.cpp"
).read_text(encoding="utf-8")
MAP_RENDERER_SOURCE = (
    ESP32_ROOT / "lib" / "maps" / "src" / "maps.cpp"
).read_text(encoding="utf-8")
MAP_HEADER_SOURCE = (
    ESP32_ROOT / "lib" / "maps" / "src" / "maps.hpp"
).read_text(encoding="utf-8")
BUILDING_ADMISSION_SOURCE = (
    ESP32_ROOT / "lib" / "maps" / "src" / "mapBuildingAdmission.hpp"
).read_text(encoding="utf-8")
ROUTE_SOURCE = (
    ESP32_ROOT / "lib" / "route_overlay" / "route_overlay.cpp"
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
    """Supplemental wiring guards; behavioral contracts live in C++ tests."""

    def test_ui_submission_path_contains_no_storage_or_raster_work(self):
        generate = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::generateVectorMap"
        )
        self.assertIn("buildRenderRequest", generate)
        self.assertIn("submitRenderRequest", generate)
        for forbidden in (
            "getMapBlocks",
            "readVectorMap",
            "readMapBlock",
            "fillPolygon",
            "renderSurfaces",
            "lv_canvas_set_buffer",
        ):
            self.assertNotIn(forbidden, generate)

        ui_tick = function_body(MAIN_SCREEN_SOURCE, "static bool prepareVisibleMapUpdate")
        self.assertIn("serviceRenderPipeline", ui_tick)
        self.assertIn("updatePositionOverlay", ui_tick)
        self.assertNotIn("readVectorMap", ui_tick)
        self.assertNotIn("getMapBlocks", ui_tick)

    def test_worker_owns_block_io_and_raw_back_buffer_only(self):
        worker = function_body(MAP_RENDERER_SOURCE, "void Maps::renderWorkerLoop")
        self.assertIn("getMapBlocks", worker)
        self.assertIn("readVectorMap", worker)
        self.assertIn("map_surface::Rgb565Surface target", worker)
        self.assertIn("bufMapTemp", worker)
        self.assertIn("shouldCancelMapRenderWork", worker)
        self.assertNotIn("lv_canvas_set_buffer", worker)
        self.assertNotIn("lv_obj_", worker)
        self.assertNotIn("lv_img_", worker)

        raw_map = function_body(MAP_RENDERER_SOURCE, "bool Maps::readVectorMap")
        raw_labels = function_body(MAP_RENDERER_SOURCE, "bool Maps::drawStreetLabels")
        for raw_path in (raw_map, raw_labels):
            self.assertNotIn("lv_", raw_path)
            self.assertNotIn("canvas", raw_path.lower())

    def test_publication_rejects_stale_frame_then_swaps_complete_buffers(self):
        publish = function_body(MAP_RENDERER_SOURCE, "bool Maps::publishReadyFrame")
        self.assertLess(
            publish.index("renderResultStillCurrent"),
            publish.index("std::swap(bufMapScreen, bufMapTemp)"),
        )
        self.assertIn("rejectReadyAsStale", publish)
        current = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::renderRequestStillCurrent"
        )
        self.assertIn("request.version.navigationEpoch == navigationEpoch", current)
        self.assertIn("request.version.styleEpoch == styleEpoch", current)
        self.assertIn("request.version.projectionEpoch == projectionEpoch", current)
        self.assertIn("std::swap(bufMapScreenSize, bufMapTempSize)", publish)
        self.assertIn("lv_canvas_set_buffer(canvasMap, bufMapScreen", publish)
        self.assertIn("lv_obj_clear_flag(canvasMap, LV_OBJ_FLAG_HIDDEN)", publish)

    def test_live_route_and_marker_share_presented_frame_transform(self):
        foreground = function_body(MAP_RENDERER_SOURCE, "void Maps::renderLiveForeground")
        marker = function_body(MAP_RENDERER_SOURCE, "void Maps::updatePositionOverlay")
        frame = function_body(
            MAP_RENDERER_SOURCE, "void Maps::updatePresentedFrameTransform"
        )
        self.assertIn("RoutePresentationTransform presentation", foreground)
        self.assertIn("visibleRenderResult.overscanPixels", foreground)
        self.assertIn("presentedPose", foreground)
        self.assertIn("presentFramePoint", marker)
        self.assertIn("visibleRenderResult.overscanPixels", marker)
        self.assertIn("lv_image_set_pivot", frame)
        self.assertIn("screenAnchorX", frame)
        self.assertIn("rotationDelta", frame)
        self.assertIn("map_presentation::presentFramePoint", ROUTE_SOURCE)

    def test_guidance_session_accepts_route_or_maneuver_packets(self):
        navigation_signature = function_body(
            MAP_RENDERER_SOURCE, "uint64_t Maps::navigationSignature"
        )
        pose = function_body(MAP_RENDERER_SOURCE, "void Maps::updatePresentedPose")
        self.assertIn("routeOverlay.hasRoute() || hasCurrentNavigationData()", navigation_signature)
        self.assertIn("routeActive || maneuverActive", pose)
        self.assertIn("headingResolver.resolve", pose)
        self.assertIn("gps.gpsData.heading < 360U", pose)

    def test_idle_guidance_screen_keeps_birdseye_3d_enabled(self):
        capture = function_body(
            MAP_RENDERER_SOURCE, "Maps::RenderContext Maps::captureRenderContext"
        )
        render = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::readVectorMap"
        )
        self.assertIn(
            "context.guidanceScreenActive = isMapGuidanceScreenActive()",
            capture,
        )
        self.assertIn(
            "buildingsVisible, context.guidanceScreenActive",
            render,
        )
        self.assertIn("navigationSessionActive", capture)

    def test_position_only_requests_do_not_cancel_active_render(self):
        job = (ESP32_ROOT / "lib" / "maps" / "src" / "mapRenderJob.hpp").read_text(
            encoding="utf-8"
        )
        self.assertIn("Version::sameFrame(active_, latest_)", job)
        self.assertIn("state_ == State::Ready", job)
        self.assertIn("requestCancellation", job)
        self.assertIn("gMapRenderCancellationGeneration", MAP_RENDERER_SOURCE)

    def test_building_admission_is_spatial_bounded_and_allocation_only_fallback(self):
        render = function_body(MAP_RENDERER_SOURCE, "bool Maps::readVectorMap")
        self.assertIn("map_building_admission::retainNearest", render)
        self.assertIn("map_building_admission::select", render)
        self.assertIn("const map_building_admission::Quotas quotas", render)
        self.assertIn("maximumExtrudedRecords", BUILDING_ADMISSION_SOURCE)
        self.assertIn("admissionDiagnostics.flat", render)
        self.assertIn("buildingAllocationFailed", render)
        self.assertIn('failure=allocation fallback=bounded-flat', render)
        self.assertIn('fallbackDiagnostics.allocationFallback = true', render)
        self.assertNotIn("deadline", render.lower())
        self.assertNotIn("kMaximumBuildingRenderTimeMs", MAP_HEADER_SOURCE)

    def test_route_is_not_baked_into_worker_base_frame(self):
        render = function_body(MAP_RENDERER_SOURCE, "bool Maps::readVectorMap")
        worker = function_body(MAP_RENDERER_SOURCE, "void Maps::renderWorkerLoop")
        foreground = function_body(MAP_RENDERER_SOURCE, "void Maps::renderLiveForeground")
        self.assertNotIn("drawRoute", render)
        self.assertNotIn("drawSnapshot", worker)
        self.assertIn("RouteOverlay::drawSnapshot", foreground)

    def test_main_screen_entry_defers_first_render_to_configured_screen(self):
        load = function_body(LVGL_SETUP_SOURCE, "void loadMainScreen")
        self.assertEqual(load.count("main_screen_entry_policy::enter("), 1)
        self.assertEqual(load.count("showConfiguredDefaultMainScreen()"), 1)
        self.assertNotIn("generateVectorMap", load)
        self.assertNotIn("generateRenderMap", load)
        self.assertNotIn("displayMap", load)


if __name__ == "__main__":
    unittest.main()
