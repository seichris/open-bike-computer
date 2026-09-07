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
