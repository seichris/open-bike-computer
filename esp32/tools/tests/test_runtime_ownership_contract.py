from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text()


class RuntimeOwnershipContractTests(unittest.TestCase):
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
        self.assertLess(cleanup, worker.index("workerTask_ = nullptr;", cleanup))

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
        self.assertIn("MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT", flash)
        self.assertIn("writeBuffer_", flash)
        self.assertIn("uxTaskGetStackHighWaterMark", flash)
        self.assertIn("flashOwnerStackHighWaterBytes", ota)

    def test_wifi_mutation_and_ota_share_internal_stack_owner(self):
        flash = source("lib/firmware_update/device_operation_owner.cpp")
        http = source("lib/device_transfer/device_transfer_http.cpp")
        for operation in (
            "WiFi.persistent(false)",
            "WiFi.mode(WIFI_STA)",
            "WiFi.begin(",
            "WiFi.disconnect(",
            "WiFi.mode(WIFI_AP)",
            "WiFi.softAP(",
            "WiFi.softAPdisconnect(",
            "WiFi.mode(WIFI_OFF)",
        ):
            self.assertIn(operation, flash)
            self.assertNotIn(operation, http)
        self.assertIn("setNetworkOperationOwner(&operationOwner_)",
                      source("lib/firmware_update/firmware_update_http.cpp"))
        self.assertGreaterEqual(
            flash.count("esp_wifi_set_storage(WIFI_STORAGE_RAM)"), 2
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
        flash = source("lib/firmware_update/device_operation_owner.cpp")
        http = source("lib/device_transfer/device_transfer_http.cpp")
        ble = source("lib/ble_navigation/ble_navigation.cpp")
        ap = flash[flash.index("case Operation::StartAccessPoint:"):
                   flash.index("case Operation::StopAccessPoint:")]
        for step in ("Mode", "RamStorage", "AccessPoint"):
            self.assertIn(f"NetworkStartStep::{step}", ap)
        for phase in ("mode", "ramStorage", "accessPoint"):
            self.assertIn(f"networkStart.{phase}.before = networkMemory()", ap)
            self.assertIn(f"networkStart.{phase}.after = networkMemory()", ap)
        self.assertIn("networkStartCode(apStart.failedStep)", http)
        self.assertIn('"wifiStartFailure"', ble)
        self.assertNotIn("apPassphrase.c_str()", http)

    def test_owner_is_reclaimed_after_network_teardown(self):
        flash = source("lib/firmware_update/device_operation_owner.cpp")
        http = source("lib/device_transfer/device_transfer_http.cpp")
        worker = http[http.index("void HttpTransferServer::runWorker"):
                      http.index("void HttpTransferServer::workerTaskThunk")]
        self.assertIn("Operation::Shutdown", flash)
        self.assertIn("vTaskDeleteWithCaps(workerTask_)", flash)
        self.assertIn("DispatchState::Poisoned", flash)
        self.assertGreaterEqual(worker.count("networkOperationOwner_->release()"), 2)
        self.assertLess(worker.index("stopNetwork();"),
                        worker.index("networkOperationOwner_->release()"))

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
        self.assertIn('snapshot.recorderReady ? "true" : "false"', recorder)


if __name__ == "__main__":
    unittest.main()
