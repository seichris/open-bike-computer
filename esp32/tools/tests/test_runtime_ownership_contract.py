from pathlib import Path
import unittest
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text()


class RuntimeOwnershipContractTests(unittest.TestCase):
    def test_175_prepares_wifi_through_internal_owner_before_ble(self):
        main = source("src/main.cpp")
        setup = main[main.index("void setup()") : main.index("void loop()")]
        prepare = setup.index("operationOwner()->prepareWiFi()")
        self.assertLess(setup.index("Network.begin()"), prepare)
        self.assertLess(prepare, setup.index("bleNavServer.init("))
        # 1.75-only and outside maintenance; 2.06 startup order is unchanged.
        guard = setup.rindex("#if", 0, prepare)
        self.assertTrue(setup.startswith("#if defined(WAVESHARE_AMOLED_175)\n", guard))
        self.assertLess(setup.rindex("if (!firmware_maintenance::active()) {", 0, prepare), prepare)
        # A crash or hang in early preparation must not repeat toward safe mode.
        deferral = setup.index("consecutiveEarlyFailures != 0")
        self.assertLess(deferral, prepare)
        self.assertLess(setup.index("} else {", deferral), prepare)
        runtime = source("lib/firmware_update/device_wifi_runtime.cpp")
        start = runtime[runtime.index("device_transfer::NetworkStartResult DeviceWiFiRuntime::start("):
                        runtime.index("esp_err_t DeviceWiFiRuntime::stop()")]
        # Every post-preparation radio start keeps the floor's total headroom.
        self.assertLess(start.index("const bool resident = initialized_"), start.index("prepare(memory)"))
        self.assertLess(start.index("wifiRadioStartMemoryAboveObservedFailure("),
                        start.index("esp_wifi_set_mode("))
        owner = source("lib/firmware_update/device_operation_owner.cpp")
        self.assertIn("execute(Command{Operation::PrepareWiFi}, result)", owner)
        self.assertIn("result.networkStart = wifi_.prepare(networkMemory);", owner)
        # Cache-disabling native Wi-Fi initialization stays off the UI/PSRAM
        # workers, including the new early preparation path.
        self.assertNotIn("esp_wifi_init(", main)

    def test_actual_metadata_reads_are_cache_safe_and_owner_reentrant(self):
        header = source("lib/firmware_update/device_operation_owner.hpp")
        header = "\n".join(line for line in header.splitlines()
                           if not line.startswith(("#include", "#pragma")))
        header = header.replace(" : public device_transfer::NetworkOperationOwner", "")
        header = header.replace(" override", "").replace("private:", "public:")
        text = source("lib/firmware_update/device_operation_owner.cpp")
        methods = text[text.index("bool DeviceOperationOwner::callerStackIsInternal()"):
                       text.index("esp_err_t DeviceOperationOwner::acceptFirmwareOperation")]
        cases = text[text.index("    case Operation::ProtectMetadataReaderFloor:"):
                     text.index("    case Operation::SelectBoot:",
                                text.index("    case Operation::ProtectMetadataReaderFloor:"))]
        harness = source("tools/tests/device_operation_metadata_read_harness.cpp")
        harness = harness.replace("// PRODUCTION_HEADER", header)
        harness = harness.replace("// PRODUCTION_METHODS", "namespace firmware_update {\n" + methods + "\n}")
        harness = harness.replace("// PRODUCTION_READ_CASES", cases)
        with tempfile.TemporaryDirectory() as directory:
            unit = Path(directory) / "metadata.cpp"
            binary = Path(directory) / "metadata"
            unit.write_text(harness)
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "tools/tests"), str(unit), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
            # Reintroduce the observed unguarded shortcut only in a temporary
            # copy. It must hit the fake cache-safety fault, not merely fail to
            # compile or trip an unrelated assertion.
            unsafe = harness.replace("if (callerStackIsInternal()) {", "if (true) {", 1)
            self.assertNotEqual(unsafe, harness)
            unit.write_text(unsafe)
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "tools/tests"), str(unit), "-o", str(binary)], check=True)
            self.assertEqual(subprocess.run([str(binary)]).returncode, 42)

    def test_actual_internal_stack_calls_wait_on_owner_and_never_run_on_psram(self):
        header = source("lib/firmware_update/device_operation_owner.hpp")
        header = "\n".join(line for line in header.splitlines()
                           if not line.startswith(("#include", "#pragma")))
        header = header.replace(" : public device_transfer::NetworkOperationOwner", "")
        header = header.replace(" override", "").replace("private:", "public:")
        text = source("lib/firmware_update/device_operation_owner.cpp")
        methods = text[text.index("bool DeviceOperationOwner::runOnInternalStack("):
                       text.index("bool DeviceOperationOwner::stopAccessPoint(")]
        methods += text[text.index("bool DeviceOperationOwner::callerStackIsInternal()"):
                        text.index("esp_err_t DeviceOperationOwner::protectMetadataReaderFloor(")]
        case = text[text.index("    case Operation::InternalStackCall:"):
                    text.index("    case Operation::Quiesce:")]
        harness = source("tools/tests/device_operation_internal_call_harness.cpp")
        harness = harness.replace("// PRODUCTION_HEADER", header)
        harness = harness.replace("// PRODUCTION_METHODS", "namespace firmware_update {\n" + methods + "\n}")
        harness = harness.replace("// PRODUCTION_CASE", case)
        with tempfile.TemporaryDirectory() as directory:
            unit = Path(directory) / "internal_call.cpp"
            binary = Path(directory) / "internal_call"
            compile_command = ["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                               "-I", str(ROOT / "tools/tests"), str(unit), "-o", str(binary)]
            unit.write_text(harness)
            subprocess.run(compile_command, check=True)
            subprocess.run([str(binary)], check=True)
            # Dropping the stack check in a temporary copy must reach the fake
            # flash fault, not merely fail to compile or trip another assert.
            unsafe = harness.replace("if (callerStackIsInternal()) {", "if (true) {", 1)
            self.assertNotEqual(unsafe, harness)
            unit.write_text(unsafe)
            subprocess.run(compile_command, check=True)
            self.assertEqual(subprocess.run([str(binary)]).returncode, 42)

    def test_diagnostics_http_reads_ffat_through_the_internal_owner(self):
        # The TLS worker's stack stays in PSRAM. Its only flash-backed storage
        # is the FFat fallback, so the network owner provides the call path.
        http = source("lib/device_transfer/device_transfer_http.cpp")
        server = http[http.index("bool HttpTransferServer::runOnInternalStack("):
                      http.index("bool HttpTransferServer::registerHandler(")]
        # The call may need the state lock, so it is never held across it.
        self.assertLess(server.index("unlockState();"),
                        server.index("owner->runOnInternalStack(call, context)"))
        self.assertIn('requestedMode == "diagnostics"', http)
        owner = source("lib/device_transfer/device_transfer_network_owner.hpp")
        self.assertIn("virtual bool runOnInternalStack(void (*)(void *), void *) { return false; }",
                      owner)
        self.assertIn("bool runOnInternalStack(void (*call)(void *), void *context) override;",
                      source("lib/firmware_update/device_operation_owner.hpp"))

    def test_actual_wifi_runtime_reuses_driver_with_radio_off_and_credentials_erased(self):
        header = source("lib/firmware_update/device_wifi_runtime.hpp")
        methods = source("lib/firmware_update/device_wifi_runtime.cpp")
        def without_includes(text):
            return "\n".join(line for line in text.splitlines()
                             if not line.startswith(("#include", "#pragma")))
        harness = source("tools/tests/device_wifi_runtime_harness.cpp")
        harness = harness.replace("// PRODUCTION_HEADER", without_includes(header))
        harness = harness.replace("// PRODUCTION_METHODS", without_includes(methods))
        with tempfile.TemporaryDirectory() as directory:
            unit = Path(directory) / "wifi.cpp"
            unit.write_text(harness)
            binary = Path(directory) / "wifi"
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "tools/tests"), str(unit), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_ota_terminal_cleanup_belongs_to_http_owner(self):
        ota = source("lib/firmware_update/firmware_update_http.cpp")
        disable = ota[ota.index("bool FirmwareUpdateHttpServer::setEnabled"):
                      ota.index("void FirmwareUpdateHttpServer::workerWillStop")]
        self.assertNotIn("resetUploadState();", disable)
        self.assertIn("workerWillStop() { resetUploadState(); }", ota)
        http = source("lib/device_transfer/device_transfer_http.cpp")
        worker = http[http.index("void HttpTransferServer::runWorker"):
                      http.index("void HttpTransferServer::workerTaskThunk")]
        cleanup = worker.index("handlers_[index].handler->workerWillStop();")
        self.assertLess(cleanup, worker.index("stopNetwork();", cleanup))
        self.assertNotIn("workerTask_ = nullptr;", worker)
        thunk = http[http.index("void HttpTransferServer::workerTaskThunk"):
                     http.index("HttpTransferStatus HttpTransferServer::status")]
        self.assertLess(thunk.index("server->runWorker();"),
                        thunk.index("server->workerStopped_ = true;"))
        owner = http[http.index("void HttpTransferServer::process()"):
                     http.index("void HttpTransferServer::workerTaskThunk")]
        self.assertLess(owner.index("vTaskDeleteWithCaps(worker);"),
                        owner.index("workerTask_ = nullptr;"))

    def test_firmware_tls_and_flash_have_separate_stack_owners(self):
        ota = source("lib/firmware_update/firmware_update_http.cpp")
        flash = source("lib/firmware_update/device_operation_owner.cpp")
        http = source("lib/device_transfer/device_transfer_http.cpp")

        maintenance_psram = 'requestedMode == "firmware"'
        self.assertIn(maintenance_psram, http)
        for operation in (
            "esp_ota_begin(",
            "esp_ota_write(",
            "esp_ota_end(",
            "esp_ota_abort(",
            "esp_ota_get_partition_description(",
            "esp_ota_set_boot_partition(",
        ):
            self.assertIn(operation, flash)
            self.assertNotIn(operation, ota)
        self.assertIn("esp_ptr_internal(workerStack_)", flash)
        self.assertIn("writeBuffer_", flash)
        self.assertIn("uxTaskGetStackHighWaterMark", flash)
        self.assertIn("flashOwnerStackHighWaterBytes", ota)

    def test_wifi_mutation_and_ota_share_internal_stack_owner(self):
        flash = source("lib/firmware_update/device_operation_owner.cpp")
        http = source("lib/device_transfer/device_transfer_http.cpp")
        runtime = source("lib/firmware_update/device_wifi_runtime.cpp")
        for operation in ("esp_wifi_init(", "esp_wifi_set_mode(",
                          "esp_wifi_set_config(", "esp_wifi_start(",
                          "esp_wifi_connect(", "esp_wifi_stop("):
            self.assertIn(operation, runtime)
            self.assertNotIn(operation, http)
        self.assertIn("wifi_.start(", flash)
        self.assertIn("wifi_.stop()", flash)
        self.assertNotIn("WiFi.mode(", flash)
        self.assertNotIn("esp_wifi_deinit(", runtime)
        self.assertIn("setNetworkOperationOwner(&operationOwner_)",
                      source("lib/firmware_update/firmware_update_http.cpp"))
        self.assertGreaterEqual(
            runtime.count("esp_wifi_set_storage(WIFI_STORAGE_RAM)"), 2
        )
        self.assertIn("internalOwnerStackHighWaterBytes", http)

    def test_internal_owner_timeout_is_terminal_for_this_boot(self):
        flash = source("lib/firmware_update/device_operation_owner.cpp")
        policy = source(
            "lib/firmware_update/firmware_internal_owner_policy.hpp"
        )
        self.assertIn("commandTimedOut", flash)
        self.assertIn("result.commandId == queuedCommand.id", flash)
        self.assertIn("DispatchState::Poisoned", policy)
        self.assertIn("state == DispatchState::InFlight && matchingResult",
                      policy)

    def test_ap_failure_reports_distinct_driver_steps_and_memory(self):
        flash = source("lib/firmware_update/device_wifi_runtime.cpp")
        http = source("lib/device_transfer/device_transfer_http.cpp")
        ble = source("lib/ble_navigation/ble_navigation.cpp")
        ap = flash[flash.index("device_transfer::NetworkStartResult DeviceWiFiRuntime::prepare("):
                   flash.index("esp_err_t DeviceWiFiRuntime::stop()")]
        for step in ("Mode", "RamStorage", "AccessPoint"):
            self.assertIn(f"NetworkStartStep::{step}", ap)
        for phase in ("mode", "ramStorage", "accessPoint"):
            self.assertIn(f"result.{phase}.before = memory()", ap)
            self.assertIn(f"result.{phase}.after = memory()", ap)
        self.assertIn("networkStartCode(apStart.failedStep)", http)
        self.assertIn('"wifiStartFailure"', ble)
        self.assertNotIn("apPassphrase.c_str()", http)

    def test_owner_is_quiesced_after_network_teardown(self):
        flash = source("lib/firmware_update/device_operation_owner.cpp")
        http = source("lib/device_transfer/device_transfer_http.cpp")
        worker = http[http.index("void HttpTransferServer::runWorker"):
                      http.index("void HttpTransferServer::workerTaskThunk")]
        self.assertIn("Operation::Quiesce", flash)
        self.assertNotIn("vTaskDelete", flash)
        self.assertIn("xTaskCreateStatic(", flash)
        self.assertNotIn("xTaskCreateWithCaps", flash)
        self.assertNotIn("ulTaskNotifyTake", flash)
        self.assertIn("DispatchState::Poisoned", flash)
        self.assertGreaterEqual(worker.count("networkOperationOwner_->release()"), 2)
        self.assertLess(worker.index("stopNetwork();"),
                        worker.index("networkOperationOwner_->release()"))

    def test_actual_static_owner_reuses_stack_and_fails_closed(self):
        # Compile the production class/storage and actual start/release methods;
        # only the platform task/queue APIs are faked. This does not qualify
        # target scheduling, Wi-Fi or flash-cache behavior.
        header = source("lib/firmware_update/device_operation_owner.hpp")
        header = "\n".join(line for line in header.splitlines()
                           if not line.startswith(("#include", "#pragma")))
        header = header.replace(" : public device_transfer::NetworkOperationOwner", "")
        header = header.replace(" override", "").replace("private:", "public:")
        flash = source("lib/firmware_update/device_operation_owner.cpp")
        methods = flash[flash.index("void DeviceOperationOwner::configure()"):
                        flash.index("bool DeviceOperationOwner::started()")]
        methods += flash[flash.index("esp_err_t DeviceOperationOwner::execute("):
                         flash.index("void DeviceOperationOwner::run()")]
        quiesce = flash[flash.index("    case Operation::Quiesce:"):
                        flash.index("    }\n    lastStackHighWaterBytes_", flash.index("    case Operation::Quiesce:"))]
        # Run the exact owner-side clearing before publishing its fake reply.
        quiesce = quiesce.replace("case Operation::Quiesce:", "case Owner::Operation::Quiesce:")
        for field in ("networkSsid_", "networkPassword_", "mapSessionId_", "writeBuffer_"):
            quiesce = quiesce.replace(field, "owner->" + field)
        quiesce = quiesce.replace("wifi_.stop()", "owner->wifi_.stop()")
        harness = source("tools/tests/device_operation_static_stack_harness.cpp")
        harness = harness.replace("// PRODUCTION_HEADER", header)
        harness = harness.replace("// PRODUCTION_METHODS", "namespace firmware_update {\n" + methods + "\n}")
        harness = harness.replace("// PRODUCTION_QUIESCE", quiesce)
        with tempfile.TemporaryDirectory() as directory:
            unit = Path(directory) / "owner.cpp"
            unit.write_text(harness)
            binary = Path(directory) / "owner"
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "tools/tests"), str(unit), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_all_socket_close_paths_withdraw_interrupt_capability(self):
        tls = source("lib/device_transfer/device_transfer_tls.cpp")
        close = tls[tls.index("void TransferClient::stop()") :]
        self.assertLess(close.index("interruptLease_.withdraw()"),
                        close.index("esp_tls_server_session_delete"))
        self.assertLess(close.index("interruptLease_.withdraw()"),
                        close.index("socketOwner_.stop()"))
        self.assertIn("interruptLease_.publish(socket_)", tls)

    def test_handler_locks_do_not_depend_on_heap_success(self):
        for path in ("lib/firmware_update/firmware_update_http.cpp",
                     "lib/map_transfer_http/map_transfer_http.cpp"):
            text = source(path)
            self.assertIn("xSemaphoreCreateMutexStatic(&stateMutexStorage_)", text)
            self.assertNotIn("stateMutex_ = xSemaphoreCreateMutex();", text)

    def test_display_has_no_partial_full_mode_fallback_or_infinite_wait(self):
        panel = source("lib/panel/WAVESHARE_AMOLED_175.cpp")
        setup = panel[panel.index("void setupLVGLforArduinoGFX()") :]
        self.assertIn("full_frame_allocation::reserve", setup)
        self.assertIn("LV_DISPLAY_RENDER_MODE_FULL", setup)
        self.assertNotIn("/ 10", setup)
        self.assertNotIn("while (1)", setup)
        self.assertIn('failDisplayInitialization("full_frame_buffers")', setup)
        self.assertIn("std::abort();", panel)

    def test_rollback_is_worker_control_not_ui_filesystem(self):
        main = source("src/main.cpp")
        loop = main[main.index("void loop()") :]
        self.assertNotIn("rollbackActiveMap(", loop)
        self.assertNotIn("mapInstaller.readActiveMap(", loop)
        self.assertIn("mapTransferHttp.submitPendingRollback()", loop)
        http = source("lib/map_transfer_http/map_transfer_http.cpp")
        acknowledge = http[http.index("void MapTransferHttpServer::acknowledgeActivatedMapRoot"):
                           http.index("bool MapTransferHttpServer::requestRuntimeRollback")]
        self.assertNotIn("rollbackActiveMap(", acknowledge)
        maps = source("lib/maps/src/maps.cpp")
        self.assertIn("processPendingStorageControl() || processPendingVectorMapActivation()", maps)
        admission = maps[maps.index("bool Maps::requestStorageControl"):
                         maps.index("bool Maps::processPendingStorageControl")]
        self.assertIn("renderer_diagnostics::JobEvent::Stale", admission)
        worker = maps[maps.index("bool Maps::processPendingStorageControl"):
                      maps.index("bool Maps::requestVectorMapFolderActivation")]
        self.assertLess(worker.index("Phase::MapActivation"), worker.index("work(context)"))
        self.assertLess(worker.index("work(context)"), worker.index("Phase::Waiting"))
        activation = maps[maps.index("bool Maps::processPendingVectorMapActivation"):
                          maps.index("bool Maps::takeVectorMapFolderActivationResult")]
        self.assertLess(activation.index("MAPIO: activation-ready"),
                        activation.index("std::move(request.folder)"))

    def test_resource_rejection_preserves_retry_and_front(self):
        route = source("lib/route_overlay/route_overlay.cpp")
        self.assertIn("catch (const std::bad_alloc &)", route)
        self.assertLess(route.index("parsed.reserve"), route.index("points.swap(parsed)"))
        ble = source("lib/ble_navigation/ble_navigation.cpp")
        self.assertLess(ble.index("if (!routeOverlay.parseRouteData(data, len))"),
                        ble.index("lastRouteHash = hash;"))
        maps = source("lib/maps/src/maps.cpp")
        self.assertIn('"MAP_RESOURCE_REJECTED: preserving prior frame"', maps)
        self.assertIn("std::unique_ptr<MapBlock> blockOwner", maps)
        self.assertIn("result.folder = std::move(completedVectorMapActivation.folder)", maps)

    def test_waiting_screen_precedes_map_recovery_without_moving_acceptance(self):
        main = source("src/main.cpp")
        setup = main[main.index("void setup()") : main.index("void loop()")]
        storage_done = setup.index(
            "boot_diagnostics::completeStage(boot_diagnostics::Stage::Storage);")
        guard = "#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)\n"
        waveshare = setup[setup.rindex(guard, 0, storage_done):]
        # The real waiting screen is on the panel before any map recovery work.
        # Recovery still precedes the diagnostics writer, Wi-Fi preparation,
        # BLE and acceptance, so a map failure keeps OTA rollback and safe mode.
        steps = (
            "boot_diagnostics::completeStage(boot_diagnostics::Stage::Storage);",
            "boot_diagnostics::enterStage(boot_diagnostics::Stage::UserInterface);",
            "startUserInterface();",
            "lv_screen_load(waitingScreen);",
            "lv_refr_now(display);",
            '"waiting_screen"',
            "boot_diagnostics::completeStage(boot_diagnostics::Stage::UserInterface);",
            "boot_diagnostics::enterStage(boot_diagnostics::Stage::MapRecovery);",
            "mapInstaller.recoverInterruptedActivation()",
            "mapView.activateVectorMapFolderDetailed(root)",
            "ride_diagnostics::startWriter();",
            "boot_diagnostics::completeStage(boot_diagnostics::Stage::MapRecovery);",
            "Network.begin()",
            "operationOwner()->prepareWiFi()",
            'bleNavServer.init("BikeComputer")',
            "!firmwareUpdateHttp.markRunningAppValid()",
            "boot_diagnostics::markReady()",
        )
        positions = [waveshare.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        # That frame precedes BLE's ownership load, so the screen starts from
        # the fail-closed claimed state, never the add-device Welcome.
        waiting = source("lib/gui/src/waitingScr.cpp")
        create = waiting[waiting.index("void createWaitingScr()"):
                         waiting.index("void updateWaitingOwnershipStatus(")]
        self.assertIn("ownershipUnknownSnapshot()", create)
        self.assertNotIn("applyPhase(Phase::Welcome", create)
        # BLE forwards every pending ownership snapshot, so an unclaimed
        # device still moves to Welcome on the first loop() pass.
        ble = source("lib/ble_navigation/ble_navigation.cpp")
        apply_update = ble[ble.index("static void applyPendingOwnershipUiUpdate()"):]
        apply_update = apply_update[:apply_update.index("\n}\n")]
        self.assertIn("if (pending) {", apply_update)
        self.assertIn("updateWaitingOwnershipStatus(nextSnapshot);", apply_update)
        # AMOLED builds never run the legacy splash, which draws outside LVGL
        # and would otherwise overwrite the early waiting-screen frame.
        splash = setup.index("splashScreen();")
        self.assertEqual(setup.count("splashScreen();"), 1)
        self.assertTrue(setup[:splash].rstrip().endswith(
            "#if !defined(WAVESHARE_AMOLED_175) && !defined(WAVESHARE_AMOLED_206)\n"
            '  log_i("Loading Splash Screen...");'))
        # One static frame: setup never runs LVGL timers or input callbacks.
        self.assertNotIn("lv_timer_handler", setup)
        self.assertEqual(setup.count("startUserInterface();"), 2)
        self.assertIn("#if !defined(WAVESHARE_AMOLED_175) && "
                      "!defined(WAVESHARE_AMOLED_206)\n", setup)
        # Other boards keep their original late waiting-screen load.
        self.assertEqual(setup.count("lv_screen_load(waitingScreen);"), 2)
        late = setup.rindex("lv_screen_load(waitingScreen);")
        self.assertTrue(setup[:late].rstrip().endswith(
            '#else\n  log_i("Loading Waiting Screen...");'))

    def test_ready_reporting_follows_boot_confirmation(self):
        main = source("src/main.cpp")
        setup = main[main.index("void setup()") : main.index("void loop()")]
        # Keep current-main's fail-closed confirmation: no early acceptance
        # or duplicate ready records while integrating recorder observability.
        confirmation = setup.index("!firmwareUpdateHttp.markRunningAppValid()")
        ready = setup.index("boot_diagnostics::markReady()")
        recorder = setup.index("recorder_ready=%u ui_ready=1")
        self.assertEqual(setup.count("markRunningAppValid()"), 1)
        self.assertEqual(setup.count('log_i("Setup Complete")'), 1)
        self.assertLess(setup.index("power_management::completeStartup()"), confirmation)
        self.assertLess(confirmation, ready)
        self.assertLess(ready, recorder)
        self.assertLess(setup.index("firmwareUpdateHttp.rejectRunningApp()"), ready)

    def test_recorder_reports_degraded_startup(self):
        recorder = source("lib/ride_diagnostics/ride_diagnostics.cpp")
        self.assertIn("recorderResourcesReady.store(resourcesReady", recorder)
        self.assertIn("recorderWriterReady.store(created == pdPASS", recorder)
        self.assertIn("if (created != pdPASS)", recorder)
        self.assertIn('"writer_unavailable"', recorder)
        self.assertIn("recorder_ready=%u ui_ready=1", source("src/main.cpp"))
        self.assertIn('snapshot.recorderReady ? "true" : "false"',
                      source("lib/ride_diagnostics/ride_diagnostics_http.cpp"))
        self.assertIn("formatRecorderHealthFields", recorder)
        self.assertIn('snapshot.recorderReady ? "true" : "false"',
                      source("lib/ride_diagnostics/ride_diagnostics_format.hpp"))


if __name__ == "__main__":
    unittest.main()
