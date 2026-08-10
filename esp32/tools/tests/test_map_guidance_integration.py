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
MAIN_SOURCE = (ESP32_ROOT / "src" / "main.cpp").read_text(encoding="utf-8")


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

    def test_render_worker_stack_uses_psram_to_preserve_wifi_headroom(self):
        start = function_body(MAP_RENDERER_SOURCE, "bool Maps::startRenderWorker")
        thunk = function_body(
            MAP_RENDERER_SOURCE, "void Maps::renderWorkerTaskThunk"
        )
        self.assertIn("xTaskCreatePinnedToCoreWithCaps", start)
        self.assertIn("MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT", start)
        self.assertNotIn("xTaskCreatePinnedToCore(", start)
        self.assertIn("vTaskDeleteWithCaps(nullptr)", thunk)
        self.assertNotIn("vTaskDelete(nullptr)", thunk)

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
        self.assertLess(
            publish.index("frameCoversViewport"),
            publish.index("std::swap(bufMapScreen, bufMapTemp)"),
        )

    def test_live_route_and_marker_share_presented_frame_transform(self):
        foreground = function_body(MAP_RENDERER_SOURCE, "void Maps::renderLiveForeground")
        marker = function_body(MAP_RENDERER_SOURCE, "void Maps::updatePositionOverlay")
        frame = function_body(
            MAP_RENDERER_SOURCE, "void Maps::updatePresentedFrameTransform"
        )
        self.assertIn("RoutePresentationTransform presentation", foreground)
        self.assertIn("visibleRenderResult.overscanPixels", foreground)
        self.assertIn("presentedPose", foreground)
        self.assertLess(
            foreground.index("!route.hasRoute()"),
            foreground.index("surface.clearAlpha()"),
        )
        self.assertLess(
            foreground.index(
                "presentationSignature == lastForegroundPresentationSignature"
            ),
            foreground.index("surface.clearAlpha()"),
        )
        self.assertLess(
            frame.index("presentationSignature == lastFramePresentationSignature"),
            frame.index("lv_image_set_pivot"),
        )
        self.assertIn("transformAlreadyApplied", frame)
        self.assertIn("presentFramePoint", marker)
        self.assertIn("visibleRenderResult.overscanPixels", marker)
        self.assertIn("lv_image_set_pivot", frame)
        self.assertIn("screenAnchorX", frame)
        self.assertIn("rotationDelta", frame)
        self.assertGreaterEqual(frame.count("frameCoversViewport"), 2)
        self.assertIn("visibleCoversPose", frame)
        self.assertIn("latestCoversPose", frame)
        self.assertNotIn("latestDx < available", frame)
        self.assertIn("map_presentation::presentFramePoint", ROUTE_SOURCE)
        self.assertIn("markerRotationDegrees", marker)
        self.assertIn("navigationActive &&", marker)
        self.assertIn("!presentedPose.headingValid", marker)
        navigation_marker = function_body(
            MAP_RENDERER_SOURCE, "static void drawNavigationMarker"
        )
        self.assertIn("rotatedMarkerPoint", navigation_marker)

    def test_overscan_canvas_position_uses_center_aligned_offset(self):
        frame = function_body(
            MAP_RENDERER_SOURCE, "void Maps::updatePresentedFrameTransform"
        )
        self.assertIn("centerAlignedOffsetForPoint", frame)
        self.assertNotIn(
            "const int16_t targetX = viewportOriginX + screenAnchorX - pivotX",
            frame,
        )
        self.assertNotIn(
            "const int16_t targetY = viewportOriginY + screenAnchorY - pivotY",
            frame,
        )

    def test_guidance_session_accepts_route_or_maneuver_packets(self):
        navigation_signature = function_body(
            MAP_RENDERER_SOURCE, "uint64_t Maps::navigationSignature"
        )
        pose = function_body(MAP_RENDERER_SOURCE, "void Maps::updatePresentedPose")
        self.assertIn("routeOverlay.hasRoute() || hasCurrentNavigationData()", navigation_signature)
        self.assertIn("routeActive || maneuverActive", pose)
        self.assertIn("headingResolver.resolve", pose)
        self.assertIn("gps.gpsData.heading < 360U", pose)
        semantics = function_body(
            MAP_RENDERER_SOURCE, "void Maps::invalidateRenderSemantics"
        )
        self.assertNotIn("routeOverlay.revision()", semantics)
        self.assertIn("posePresenter.resetHeading(nowMs)", semantics)

    def test_live_presentation_does_not_overwrite_gesture_transforms(self):
        service = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::serviceRenderPipeline"
        )
        marker = function_body(
            MAP_RENDERER_SOURCE, "void Maps::updatePositionOverlay"
        )
        drag = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::beginDragPreview"
        )
        pinch = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::beginPinchPreview"
        )
        self.assertIn("gestureActive ? false : publishReadyFrame", service)
        self.assertIn("settlementPending && !published", service)
        self.assertIn("presentationGestureOwnsTransforms", marker)
        self.assertIn("LV_OBJ_FLAG_HIDDEN", drag)
        self.assertIn("LV_OBJ_FLAG_HIDDEN", pinch)
        drag_reset = function_body(
            MAP_RENDERER_SOURCE, "void Maps::resetDragPresentationVisuals"
        )
        pinch_reset = function_body(
            MAP_RENDERER_SOURCE, "void Maps::resetPinchPresentationVisuals"
        )
        for reset in (drag_reset, pinch_reset):
            self.assertIn("lastFramePresentationSignature = 0", reset)
            self.assertIn("lastForegroundPresentationSignature = 0", reset)
        pinch_completion = function_body(
            MAP_RENDERER_SOURCE,
            "static void completePinchCanvasSettlement",
        )
        self.assertIn("lv_image_set_scale", pinch_completion)
        self.assertNotIn("lv_image_set_pivot", pinch_completion)

    def test_course_up_scheduler_honors_legacy_heading_negotiation(self):
        heading = function_body(
            MAIN_SCREEN_SOURCE,
            "static bool currentCourseUpHeading(uint16_t &headingDegrees) {",
        )
        prepare = function_body(
            MAIN_SCREEN_SOURCE, "static bool prepareVisibleMapUpdate"
        )
        self.assertIn("supportsExplicitInvalidGpsHeading", heading)
        self.assertIn("routeOverlay.headingNear", heading)
        self.assertLess(
            heading.index("supportsExplicitInvalidGpsHeading"),
            heading.index("gps.gpsData.headingValid"),
        )
        self.assertIn(
            "uiChangeTracker.take(ui_update_policy::Source::Route)", prepare
        )
        self.assertIn("if (gpsChanged || routeChanged)", prepare)
        self.assertIn("mapRenderScheduler.observe(currentMapFix())", prepare)

    def test_idle_guidance_screen_keeps_birdseye_3d_enabled(self):
        capture = function_body(
            MAP_RENDERER_SOURCE, "Maps::RenderContext Maps::captureRenderContext"
        )
        render = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::readVectorMap"
        )
        request = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::buildRenderRequest"
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
        self.assertIn(
            "else if (!request.context.navigationSessionActive)", request
        )
        self.assertIn(
            "visibleRenderResult.version.navigationEpoch ==",
            request,
        )
        self.assertLess(
            request.index("!request.context.navigationSessionActive"),
            request.index("Course-up frame deferred"),
        )

    def test_position_only_requests_do_not_cancel_active_render(self):
        job = (ESP32_ROOT / "lib" / "maps" / "src" / "mapRenderJob.hpp").read_text(
            encoding="utf-8"
        )
        self.assertIn("Version::sameFrame(active_, latest_)", job)
        self.assertIn("state_ == State::Ready", job)
        self.assertIn("requestCancellation", job)
        self.assertIn("gMapRenderCancellationGeneration", MAP_RENDERER_SOURCE)
        take = function_body(MAP_RENDERER_SOURCE, "bool Maps::takeWorkerRequest")
        worker = function_body(MAP_RENDERER_SOURCE, "void Maps::renderWorkerLoop")
        self.assertIn("request.cancellationGeneration", take)
        self.assertIn("request.cancellationGeneration", worker)
        current = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::renderRequestStillCurrent"
        )
        self.assertNotIn("routeRevision", current)

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
        self.assertIn("throw std::bad_alloc()", render)
        self.assertIn("drewFootprint", render)
        self.assertNotIn("deadline", render.lower())
        self.assertNotIn("kMaximumBuildingRenderTimeMs", MAP_HEADER_SOURCE)
        self.assertIn("CourtyardPolicy::SolidRoofFallback", render)
        self.assertIn("const bool preserveCourtyards", render)
        self.assertNotIn("++courtyardDeferred;\n          continue;", render)

    def test_late_worker_exit_has_an_explicit_restart_handoff(self):
        stop = function_body(MAP_RENDERER_SOURCE, "bool Maps::stopRenderWorker")
        recover = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::recoverRenderWorkerIfNeeded"
        )
        service = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::serviceRenderPipeline"
        )
        self.assertIn("renderWorkerRestartAfterExit.store(true", stop)
        self.assertIn("renderWorkerExited.load", recover)
        self.assertIn("startRenderWorker()", recover)
        self.assertIn("recoverRenderWorkerIfNeeded", service)

        activation = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::requestVectorMapFolderActivation"
        )
        self.assertIn("renderWorkerRestartAfterExit.load", activation)
        self.assertIn("recoverRenderWorkerIfNeeded", activation)

    def test_runtime_map_probe_and_switch_are_worker_control_jobs(self):
        loop = function_body(MAIN_SOURCE, "void loop()")
        self.assertIn("requestVectorMapFolderActivation", loop)
        self.assertIn("takeVectorMapFolderActivationResult", loop)
        self.assertNotIn("probeVectorMapFolder(", loop)
        self.assertNotIn("setVectorMapFolder(", loop)

        control = function_body(
            MAP_RENDERER_SOURCE,
            "bool Maps::processPendingVectorMapActivation",
        )
        self.assertIn("probeVectorMapFolderOnStorageOwner", control)
        self.assertIn("switchVectorMapFolderOnStorageOwner", control)
        self.assertIn("gMapRenderControlOperation.store(true", control)
        self.assertIn("gMapRenderControlOperation.store(false", control)
        self.assertIn("WakeReason::Transfer", control)

        cancellation = function_body(
            MAP_RENDERER_SOURCE, "bool shouldCancelMapRenderWork"
        )
        self.assertIn("shouldCancelWorkerOperation", cancellation)

        result = function_body(
            MAP_RENDERER_SOURCE,
            "bool Maps::takeVectorMapFolderActivationResult",
        )
        self.assertIn("if (result.loaded)", result)
        self.assertIn("isPosMoved = true", result)
        self.assertIn("redrawMap = true", result)

    def test_runtime_map_activation_retries_transient_enqueue_failures(self):
        loop = function_body(MAIN_SOURCE, "void loop()")
        self.assertEqual(loop.count("requestVectorMapFolderActivation"), 1)
        self.assertIn("pendingMapRendererActivation.rendererQueued = true", loop)
        self.assertIn("kMapRendererActivationQueueTimeoutMs", loop)
        self.assertIn("queueAttemptStartedMs", MAIN_SOURCE)
        self.assertNotIn(
            "acknowledgeActivatedMapRoot(activatedMapRoot, false)", loop
        )

    def test_initial_map_canvas_allocation_does_not_stop_control_worker(self):
        create = function_body(MAP_RENDERER_SOURCE, "void Maps::createMapScrSprites")
        self.assertIn("workerCanOwnFrameStorage", create)
        self.assertIn("frameStorageMustMove && workerCanOwnFrameStorage", create)

    def test_route_is_not_baked_into_worker_base_frame(self):
        render = function_body(MAP_RENDERER_SOURCE, "bool Maps::readVectorMap")
        worker = function_body(MAP_RENDERER_SOURCE, "void Maps::renderWorkerLoop")
        foreground = function_body(MAP_RENDERER_SOURCE, "void Maps::renderLiveForeground")
        route_handler = function_body(
            (ESP32_ROOT / "lib" / "ble_navigation" / "ble_navigation.cpp").read_text(
                encoding="utf-8"
            ),
            "static void handleRouteGeometryPayload",
        )
        self.assertNotIn("drawRoute", render)
        self.assertNotIn("drawSnapshot", worker)
        self.assertIn("RouteOverlay::drawSnapshot", foreground)
        self.assertIn("hadRoute != routeOverlay.hasRoute()", route_handler)

    def test_main_screen_entry_defers_first_render_to_configured_screen(self):
        load = function_body(LVGL_SETUP_SOURCE, "void loadMainScreen")
        self.assertEqual(load.count("main_screen_entry_policy::enter("), 1)
        self.assertEqual(load.count("showConfiguredDefaultMainScreen()"), 1)
        self.assertNotIn("generateVectorMap", load)
        self.assertNotIn("generateRenderMap", load)
        self.assertNotIn("displayMap", load)

    def test_map_profile_transition_waits_for_new_frame_publication(self):
        show = function_body(MAIN_SCREEN_SOURCE, "static void showMainTile")
        self.assertNotIn("mapWasVisible", show)
        self.assertLess(
            show.index("lv_obj_add_flag(mapTile, LV_OBJ_FLAG_HIDDEN)"),
            show.index("mapTileTransition.begin()"),
        )

        prepare = function_body(
            MAIN_SCREEN_SOURCE, "static bool prepareVisibleMapUpdate"
        )
        self.assertIn("mapTileTransition.noteFramePublished()", prepare)
        self.assertLess(
            prepare.index("mapTileTransition.noteFramePublished()"),
            prepare.index("revealPendingMapTileIfReady()"),
        )


if __name__ == "__main__":
    unittest.main()
