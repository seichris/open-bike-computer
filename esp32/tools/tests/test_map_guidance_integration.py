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
MAP_PRESENTATION_SOURCE = (
    ESP32_ROOT / "lib" / "maps" / "src" / "mapPresentation.hpp"
).read_text(encoding="utf-8")
MAP_POSE_INPUT_POLICY_SOURCE = (
    ESP32_ROOT / "lib" / "maps" / "src" / "mapPoseInputPolicy.hpp"
).read_text(encoding="utf-8")
BLE_SOURCE = (
    ESP32_ROOT / "lib" / "ble_navigation" / "ble_navigation.cpp"
).read_text(encoding="utf-8")
BLE_HEADER_SOURCE = (
    ESP32_ROOT / "lib" / "ble_navigation" / "ble_navigation.hpp"
).read_text(encoding="utf-8")
GPS_FRESHNESS_SOURCE = (
    ESP32_ROOT / "lib" / "ble_navigation" / "gps_input_freshness.hpp"
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
LVGL_CONFIG_SOURCE = (
    ESP32_ROOT / "lib" / "lvgl" / "lv_conf.h"
).read_text(encoding="utf-8")
LVGL_CONFIG_TEMPLATE_SOURCE = (
    ESP32_ROOT / "tools" / "lv_conf_template.h"
).read_text(encoding="utf-8")
MAIN_SOURCE = (ESP32_ROOT / "src" / "main.cpp").read_text(encoding="utf-8")
WAITING_SCREEN_SOURCE = (
    ESP32_ROOT / "lib" / "gui" / "src" / "waitingScr.cpp"
).read_text(encoding="utf-8")
SCHEDULER_DOC = (
    ESP32_ROOT.parent / "docs" / "firmware-map-render-scheduler.md"
).read_text(encoding="utf-8")
PSRAM_DOC = (
    ESP32_ROOT.parent / "docs" / "firmware-map-rendering-psram.md"
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
        self.assertIn("prepareMapScene", worker)
        preparation = function_body(MAP_RENDERER_SOURCE, "bool Maps::prepareMapScene")
        self.assertIn("getMapBlocks", preparation)
        self.assertIn("preparedScene.covers", preparation)
        self.assertNotIn("lv_", preparation)
        self.assertIn("readVectorMap", worker)
        self.assertIn("map_surface::Rgb565Surface target", worker)
        self.assertIn("bufMapTemp", worker)
        self.assertIn("shouldCancelMapRenderWork", worker)
        self.assertNotIn("lv_canvas_set_buffer", worker)
        self.assertNotIn("lv_obj_", worker)
        self.assertNotIn("lv_img_", worker)

    def test_stable_camera_uses_accepted_projection_without_bitmap_rotation(self):
        transform = function_body(MAP_RENDERER_SOURCE, "void Maps::updatePresentedFrameTransform")
        stable = transform.split("if (map_profile_protocol::STABLE_CAMERA_ENABLED)", 1)[1].split("return;", 1)[0]
        self.assertIn("lv_img_set_angle(canvasMap, 0)", stable)
        self.assertNotIn("desiredRotation", stable)
        presenter = function_body(MAP_RENDERER_SOURCE, "void Maps::serviceStableCamera")
        self.assertIn("cameraLag.observe(required, nowMs)", presenter)
        self.assertIn("cameraLag.expired(nowMs)", presenter)
        self.assertIn("visibleRenderResult.labelOrientation", presenter)
        marker = function_body(MAP_RENDERER_SOURCE, "void Maps::updatePositionOverlay")
        self.assertIn("map_camera::markerAngle(visibleProjection, rider", marker)
        self.assertIn("visibleProjection.projectWorld(rider)", marker)

    def test_frame_capture_uses_narrow_gui_owner_interface(self):
        capture = (ESP32_ROOT / "lib/device_debug/device_debug_frame_store.cpp").read_text()
        self.assertNotIn("mainScr.hpp", capture)
        self.assertIn("captureMapCameraForPanelFrame()", capture)
        self.assertIn("device_debug::captureMapCameraForPanelFrame()", MAIN_SCREEN_SOURCE)
        self.assertLess(MAIN_SCREEN_SOURCE.index("Maps mapView;"),
                        MAIN_SCREEN_SOURCE.index("device_debug::captureMapCameraForPanelFrame()"))
        widgets = (ESP32_ROOT / "lib/gui/src/widgets.hpp").read_text()
        self.assertIn('"../../utils/src/gpsMath.hpp"', widgets)

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

    def test_round_panel_sizes_overscan_without_spending_coverage_margin(self):
        request = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::buildRenderRequestForScreen"
        )
        self.assertIn("MAP_RENDER_MINIMUM_OVERSCAN_PIXELS = 64", MAP_HEADER_SOURCE)
        self.assertIn("MAP_RENDER_ROUND_VIEWPORT", request)
        self.assertIn("map_presentation::refreshLeadPixels", request)
        self.assertIn("MAP_RENDER_SAFETY_PIXELS + 8U", request)
        self.assertIn("request.overscanPixels - MAP_RENDER_SAFETY_PIXELS", request)
        self.assertIn("request.viewportWidth + request.overscanPixels * 2U", request)

    def test_amoled_lvgl_pool_uses_psram_to_preserve_wifi_headroom(self):
        gate = (
            "#if defined(BOARD_HAS_PSRAM) && "
            "(defined(WAVESHARE_AMOLED_175) || "
            "defined(WAVESHARE_AMOLED_206))"
        )
        allocator = (
            "heap_caps_aligned_alloc(16, (size), "
            "MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)"
        )
        for config in (LVGL_CONFIG_SOURCE, LVGL_CONFIG_TEMPLATE_SOURCE):
            self.assertIn(gate, config)
            self.assertIn("#define LV_MEM_SIZE (96 * 1024U)", config)
            self.assertIn(
                "#define LV_MEM_POOL_INCLUDE <esp_heap_caps.h>", config
            )
            self.assertIn(allocator, config)
            fallback = config.index("#else", config.index(gate))
            self.assertIn("#undef LV_MEM_POOL_ALLOC", config[fallback:])

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
            MAP_RENDERER_SOURCE, "Maps::navigationSignatureForScreen"
        )
        pose = function_body(
            MAP_RENDERER_SOURCE, "void Maps::updatePresentedPoseForScreen"
        )
        self.assertIn("routeOverlay.hasRoute() || hasCurrentNavigationData()", navigation_signature)
        self.assertIn("routeActive || maneuverActive", pose)
        self.assertIn("headingResolver.resolve", pose)
        self.assertIn("gps.gpsData.heading < 360U", pose)
        semantics = function_body(
            MAP_RENDERER_SOURCE, "void Maps::invalidateRenderSemanticsForScreen"
        )
        self.assertNotIn("routeOverlay.revision()", semantics)
        self.assertIn("posePresenter.resetHeading(nowMs)", semantics)

    def test_prediction_grace_is_bounded_and_reports_transport_freshness(self):
        self.assertIn("fullSpeedPredictionMs = 1500", MAP_PRESENTATION_SOURCE)
        self.assertIn("maximumPredictionMs = 2500", MAP_PRESENTATION_SOURCE)
        self.assertIn("maximumPredictionMeters = 70.0", MAP_PRESENTATION_SOURCE)
        self.assertIn("graceElapsedMs * graceElapsedMs", MAP_PRESENTATION_SOURCE)
        self.assertIn("predictionExhausted", MAP_PRESENTATION_SOURCE)

        pose = function_body(
            MAP_RENDERER_SOURCE, "void Maps::updatePresentedPoseForScreen"
        )
        self.assertIn("bleStats.lastGpsPacketMs", pose)
        self.assertIn("bleStats.gpsPacketCount", pose)
        self.assertIn("fix.timestampMs", pose)
        self.assertIn("poseInputTracker.classify", pose)
        self.assertIn("posePresenter.updateHeading", pose)
        self.assertIn("Action::ObservePhysicalFix", pose)
        self.assertIn(
            "positionSignature != lastPositionSignature_",
            MAP_POSE_INPUT_POLICY_SOURCE,
        )
        self.assertIn('"MAPIO: presentation gpsAgeMs=%lu lastGpsGapMs=%lu "', pose)
        self.assertIn('"predictionExhausted=%u exhaustionCount=%lu "', pose)

        queue = function_body(BLE_SOURCE, "static bool queueMapInput")
        gps_handler = function_body(BLE_SOURCE, "static void handleGpsPayload")
        self.assertIn("lastGpsPacketGapMs", BLE_HEADER_SOURCE)
        self.assertIn("maximumGpsPacketGapMs", BLE_HEADER_SOURCE)
        self.assertIn("gps_input_freshness::acceptsPayload", queue)
        self.assertIn("gpsReceivedAtMs = millis()", queue)
        self.assertIn("input.gpsArrivals.observe(gpsReceivedAtMs)", queue)
        self.assertIn("gpsFreshnessState.accept(arrivals)", gps_handler)
        self.assertIn("batch.firstPacketMs - lastPacketMs", GPS_FRESHNESS_SOURCE)

        self.assertIn(
            '"pose[gpsAgeMs=%lu predictionAgeMs=%lu grace=%d "',
            MAIN_SOURCE,
        )
        self.assertIn(
            '"exhausted=%d exhaustions=%lu lastExhaustedMs=%lu] "',
            MAIN_SOURCE,
        )
        self.assertIn('"gpsGapMs=%lu/%lu] "', MAIN_SOURCE)

        for documentation in (SCHEDULER_DOC, PSRAM_DOC):
            for term in (
                "1 Hz",
                "1.5",
                "2.5",
                "70 metres",
                "missed heartbeat",
            ):
                self.assertIn(term, documentation)

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
            MAP_RENDERER_SOURCE,
            "Maps::RenderContext Maps::captureRenderContextForScreen",
        )
        render = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::readVectorMap"
        )
        request = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::buildRenderRequestForScreen"
        )
        self.assertIn(
            "context.guidanceScreenActive = guidanceScreenActive",
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
        self.assertIn(
            "const map_building_admission::Quotas &quotas = context.tuning.buildings",
            render,
        )
        self.assertIn("maximumExtrudedRecords", BUILDING_ADMISSION_SOURCE)
        self.assertIn("admissionDiagnostics.flat", render)
        self.assertIn("buildingAllocationFailed", render)
        self.assertIn('failure=allocation fallback=bounded-flat', render)
        self.assertIn('fallbackDiagnostics.allocationFallback = true', render)
        self.assertIn("throw std::bad_alloc()", render)
        self.assertIn("drewFootprint", render)
        self.assertEqual(
            render.count("++renderedBuildings;"),
            2,
            "normal and bounded-flat passes both report rendered buildings",
        )
        self.assertNotIn("deadline", render.lower())
        self.assertNotIn("kMaximumBuildingRenderTimeMs", MAP_HEADER_SOURCE)
        self.assertIn("CourtyardPolicy::SolidRoofFallback", render)
        self.assertIn("const bool preserveCourtyards", render)
        self.assertNotIn("++courtyardDeferred;\n          continue;", render)
        self.assertNotIn(
            "admissionDiagnostics.deferred + metadataDeferredBuildings +\n"
            "        courtyardDeferred",
            render,
        )

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
        self.assertIn("map_probe_diagnostics::Code::RootSwitchFailed", control)
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
        self.assertIn("result.probe = completedVectorMapActivation.probe", result)
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

    def test_map_recovery_and_availability_are_persisted_to_sd_diagnostics(self):
        setup = function_body(MAIN_SOURCE, "void setup()")
        loop = function_body(MAIN_SOURCE, "void loop()")
        for event in (
            '"recovery_checked"',
            '"active_selection"',
            '"renderer_probe"',
            '"rollback_completed"',
            '"boot_selection_final"',
        ):
            self.assertIn(event, setup)
        self.assertIn("probeVectorMapFolderDetailed", setup)
        self.assertIn('recordHealth("ready")', setup)
        self.assertIn("takeMapAvailabilityTransition", loop)
        self.assertIn('"runtime_map_unavailable"', loop)
        self.assertIn('"map_data_not_found"', loop)

        publish = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::publishReadyFrame"
        )
        self.assertIn(
            "!mapAvailabilityKnown || "
            "mapAvailabilityAvailable != result.mapFound",
            publish,
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

    def test_post_pairing_navigation_can_reenter_map(self):
        route_handler = function_body(
            BLE_SOURCE, "static void handleRouteGeometryPayload"
        )
        gps_handler = function_body(BLE_SOURCE, "static void handleGpsPayload")
        ownership_update = function_body(
            WAITING_SCREEN_SOURCE, "void updateWaitingOwnershipStatus"
        )
        pending_transition = function_body(
            WAITING_SCREEN_SOURCE, "void checkPendingMapTransition"
        )

        self.assertEqual(route_handler.count("noteNavigationInputForMapEntry()"), 1)
        self.assertEqual(gps_handler.count("noteNavigationInputForMapEntry()"), 1)
        self.assertLess(
            route_handler.index("noteNavigationInputForMapEntry()"),
            route_handler.index("if (hash == lastRouteHash"),
        )
        self.assertIn("mapReentryPolicy.updatePhase(phase)", ownership_update)
        self.assertIn("pendingTransitionToMap = false", ownership_update)
        self.assertIn("mapReentryPolicy.allowsPendingMapEntry()", pending_transition)
        ble_process = function_body(BLE_SOURCE, "void BLENavigationServer::process()")
        self.assertLess(
            ble_process.index("applyPendingOwnershipUiUpdate();"),
            ble_process.index("processPendingMapInputs();"),
        )

    def test_matched_ownership_commands_always_queue_ui_snapshot(self):
        auth_handler = function_body(BLE_SOURCE, "static void handleAuthPayload")
        self.assertEqual(
            auth_handler.count(
                "ownership_ui_dispatch_policy::dispatchMatchedCommand("
            ),
            1,
        )
        self.assertEqual(auth_handler.count("queueOwnershipUiUpdate();"), 1)

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
        self.assertIn("acceptPublishedMapFrame(nowMs)", prepare)
        accept = function_body(
            MAIN_SCREEN_SOURCE, "static void acceptPublishedMapFrame"
        )
        self.assertIn("mapTileTransition.noteFramePublished()", accept)
        self.assertLess(
            accept.index("mapTileTransition.noteFramePublished()"),
            accept.index("revealPendingMapTileIfReady()"),
        )

    def test_non_map_screens_render_ahead_without_overwriting_ready_frame(self):
        show = function_body(MAIN_SCREEN_SOURCE, "static void showMainTile")
        self.assertIn("prepareNextMapScreenRenderAhead(tile);", show)
        self.assertLess(
            show.index("mapView.serviceRenderPipeline(nowMs)"),
            show.index("requestMapRender(map_render_policy::Reason::Screen)"),
        )
        self.assertIn("mapView.hasPendingRenderForCurrentScreen()", show)

        render_ahead = function_body(
            MAIN_SCREEN_SOURCE, "static void prepareNextMapScreenRenderAhead"
        )
        self.assertIn("mapView.prepareVectorMapForScreen", render_ahead)
        self.assertIn("mapView.isPosMoved = false", render_ahead)
        self.assertIn("mapView.redrawMap = false", render_ahead)
        self.assertIn("noteMapRenderReasons", render_ahead)

        renderer_prepare = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::prepareVectorMapForScreen"
        )
        self.assertIn("buildRenderRequestForScreen", renderer_prepare)
        self.assertIn("submitRenderRequest(request)", renderer_prepare)
        for forbidden in (
            "heap_caps_malloc",
            "ensureMapScreenBuffer",
            "ensureMapTempBuffer",
            "readVectorMap",
            "lv_canvas_set_buffer",
        ):
            self.assertNotIn(forbidden, renderer_prepare)

        pending = function_body(
            MAP_RENDERER_SOURCE,
            "bool Maps::hasPendingRenderForCurrentScreen",
        )
        self.assertIn("renderRequestStillCurrent(latestRenderRequest)", pending)

    def test_render_ahead_captures_destination_profile_semantics(self):
        build = function_body(
            MAP_RENDERER_SOURCE, "bool Maps::buildRenderRequestForScreen"
        )
        self.assertIn("guidanceScreenActive", build)
        self.assertIn("captureRenderContextForScreen", build)
        self.assertIn("navigationSignatureForScreen", build)
        self.assertIn("request.birdsEye", build)

    def test_map_transition_logs_render_ahead_latency(self):
        reveal = function_body(
            MAIN_SCREEN_SOURCE, "static void revealPendingMapTileIfReady() {"
        )
        self.assertIn("map transition visible after %lu ms", reveal)
        self.assertIn("mapTileTransitionUsedRenderAhead", reveal)


if __name__ == "__main__":
    unittest.main()
