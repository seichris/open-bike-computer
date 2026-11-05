from pathlib import Path
import unittest


BLE_SOURCE = (
    Path(__file__).resolve().parents[2]
    / "lib"
    / "ble_navigation"
    / "ble_navigation.cpp"
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


class BLENotificationDispatchTests(unittest.TestCase):
    def test_every_automation_entry_uses_the_mandatory_protected_boundary(self):
        # This adapter-wiring check complements executable authentication/lease
        # policy tests: it catches a forgotten guard in either fallback callback.
        for callback in (
            "class MyNavCharacteristicCallbacks",
            "class MySettingsCharacteristicCallbacks",
            "class MyRideAutomationCharacteristicCallbacks",
        ):
            body = function_body(BLE_SOURCE, callback)
            self.assertIn("decodeProtectedCommand(", body)
            self.assertLess(body.index("decodeProtectedCommand("),
                            body.index("admitRideAutomationFrame("))
            self.assertNotIn("decodeOwnershipHandshake(", body)
            self.assertNotIn("ingestTransportFrame(", body)
        protected = function_body(BLE_SOURCE, "static bool decodeProtectedCommand(")
        self.assertIn("false, scopedWatch", protected)
        decode = function_body(BLE_SOURCE, "static bool decodeSessionPayload(")
        self.assertIn("ride_command_admission::mayDecode", decode)
        self.assertIn("deviceOwnership.authorizeRideWrite", decode)

    def test_deferred_command_application_is_fenced_under_ownership_lock(self):
        apply = function_body(BLE_SOURCE, "bool BLENavigationServer::applyAuthorizedRideCommand(")
        self.assertLess(apply.index("xSemaphoreTake"), apply.index("ride_command_admission::mayApply"))
        self.assertLess(apply.index("ride_command_admission::mayApply"), apply.index("apply(context)"))
        self.assertLess(apply.index("apply(context)"), apply.index("xSemaphoreGive"))
        runtime = (Path(__file__).resolve().parents[2] / "lib" / "ride_automation" /
                   "ride_automation_runtime.cpp").read_text(encoding="utf-8")
        drain = function_body(runtime, "void processFirmwareShadow(uint32_t nowMs)")
        self.assertLess(drain.index("applyAuthorizedRideCommand"),
                        drain.index("processInboundTransportFrame"))
        self.assertIn("inbound.authorization", drain)
        # BLE host callbacks wait at most 100 ms for the ownership lock, so NVS
        # writes happen only after the locked apply returns.
        locked_apply = function_body(runtime, "bool processInboundTransportFrame(")
        for flash_write in ("persistConfiguration(", "persistStartSuppression(",
                            "snoozeStartAndPersist("):
            self.assertNotIn(flash_write, locked_apply)
        self.assertLess(drain.index("applyAuthorizedRideCommand"),
                        drain.index("commitDeferredConfiguration"))
        self.assertLess(drain.index("commitDeferredConfiguration"),
                        drain.index("sendTransportFrame"))

    def test_producers_queue_and_host_task_owns_transport_apis(self):
        enqueue = function_body(
            BLE_SOURCE, "static bool enqueueDeferredNotification"
        )
        self.assertIn("ui_scheduler::notify", enqueue)
        self.assertNotIn("ble_npl_eventq_put", enqueue)
        self.assertIn("deferredNotificationEventPending", enqueue)

        schedule = function_body(
            BLE_SOURCE, "static void scheduleDeferredNotificationEvent() {"
        )
        self.assertIn("ble_npl_eventq_put", schedule)
        self.assertIn("deferredNotificationEventScheduled", schedule)
        self.assertIn("compare_exchange_strong", schedule)

        send = function_body(
            BLE_SOURCE,
            "sendWireNotification(NimBLECharacteristic *characteristic",
        )
        self.assertIn("server->getPeerMTU", send)
        self.assertIn("ble_gatts_notify_custom", send)
        self.assertIn("BLE_HS_ENOMEM", send)
        self.assertIn("TransportResult::Retry", send)
        self.assertNotIn("characteristic->notify()", send)

        for producer in (
            function_body(BLE_SOURCE, "static void notifyMapTransferStatus"),
            function_body(
                BLE_SOURCE, "static void notifyRendererDiagnosticsStatus"
            ),
        ):
            self.assertNotIn("getPeerMTU", producer)
            self.assertIn("activePeerMtu.load", producer)

    def test_arduino_loop_does_not_drain_deferred_transport(self):
        drain = function_body(
            BLE_SOURCE, "static void processDeferredNotifications() {"
        )
        self.assertNotIn("while (true)", drain)
        self.assertIn("decideAfterAttempt", drain)
        self.assertIn("decision.consumeHead", drain)
        self.assertIn("deferredNotificationEventPending.store(true", drain)

        process = function_body(BLE_SOURCE, "void BLENavigationServer::process()")
        self.assertNotIn("processDeferredNotifications()", process)
        self.assertIn("scheduleDeferredNotificationEvent()", process)
        event_handler = function_body(
            BLE_SOURCE,
            "static void deferredNotificationEventHandler(struct ble_npl_event *event) {",
        )
        self.assertIn("processDeferredNotifications()", event_handler)
        self.assertIn(
            "deferredNotificationEventScheduled.store(false",
            event_handler,
        )
        self.assertIn("deferredNotificationEventPending.load", event_handler)
        self.assertLess(
            event_handler.index("deferredNotificationEventPending.store(false"),
            event_handler.index("processDeferredNotifications()"),
        )
        self.assertLess(
            event_handler.index("processDeferredNotifications()"),
            event_handler.index("deferredNotificationEventScheduled.store(false"),
        )
        init = function_body(
            BLE_SOURCE, "void BLENavigationServer::init(const char *deviceName)"
        )
        self.assertIn("deferredNotificationEventScheduled.store(false", init)

    def test_host_callback_refreshes_peer_mtu_before_deferring_work(self):
        callback = function_body(BLE_SOURCE, "ScopedNimbleCallback() {")
        self.assertIn("NimBLEDevice::getServer()", callback)
        self.assertIn("server->getPeerMTU(connectionHandle)", callback)
        self.assertIn("activePeerMtu.store(peerMtu", callback)
        self.assertLess(
            callback.index("server->getPeerMTU(connectionHandle)"),
            callback.index("activePeerMtu.store(peerMtu"),
        )

    def test_host_liveness_probes_cover_callbacks_and_transport(self):
        # Every characteristic write callback and the connect/disconnect
        # callbacks mark the host task's activity before any other work, so a
        # heartbeat stall names the site that held the host task and a slow
        # callback is recorded with its site.
        for signature in (
            "  void onWrite(NimBLECharacteristic *pChar) override {",
            "  void onWrite(NimBLECharacteristic *) override {",
            "  void onConnect(NimBLEServer *pServer, ble_gap_conn_desc *desc) override {",
            "                    ble_gap_conn_desc *desc) override {",
        ):
            start = 0
            found = 0
            while True:
                index = BLE_SOURCE.find(signature, start)
                if index == -1:
                    break
                found += 1
                body = BLE_SOURCE[index + len(signature):index + len(signature) + 120]
                self.assertTrue(
                    body.lstrip().startswith("HostActivityScope activity("),
                    signature,
                )
                start = index + 1
            self.assertGreater(found, 0, signature)
        self.assertEqual(BLE_SOURCE.count("  void onWrite(NimBLECharacteristic"), 9)
        send = function_body(
            BLE_SOURCE, "sendWireNotification(NimBLECharacteristic *characteristic"
        )
        self.assertLess(
            send.index('HostActivityScope activity("notify")'),
            send.index("ble_gatts_notify_custom"),
        )
        # The heartbeat is posted by the esp_timer task and handled only by
        # the host task; its post time is published before the event.
        timer = function_body(BLE_SOURCE, "static void hostHeartbeatTimerHandler(")
        self.assertIn(
            "ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &hostHeartbeatEvent)",
            timer,
        )
        self.assertLess(
            timer.index("hostHeartbeatPostedMs.store("),
            timer.index("ble_npl_eventq_put"),
        )
        handler = function_body(BLE_SOURCE, "static void hostHeartbeatEventHandler(")
        self.assertIn("nimbleHostTask.store(xTaskGetCurrentTaskHandle()", handler)
        self.assertIn("hostHeartbeatPostedMs.store(0", handler)
        # A once-per-boot proof of life makes later silence a measurement, and
        # every transfer session ends with a summary of its worst host latency.
        self.assertIn("hostHeartbeatStartedRecorded.exchange(true", handler)
        self.assertIn('recordHostHeartbeat("started"', handler)
        self.assertIn("transferWindowMaxBeatMs.store(latencyMs", handler)
        sync = function_body(BLE_SOURCE, "void BLENavigationServer::syncTransferConnectionProfile() {")
        self.assertLess(sync.index("observeTransferWindow(sessionEnabled)"),
                        sync.index("#if !BLE_RADIO_CHARACTERIZATION"))
        window = function_body(BLE_SOURCE, "static void observeTransferWindow(bool sessionEnabled) {")
        self.assertIn('\\"phase\\":\\"transfer_summary\\"', window)
        init = function_body(
            BLE_SOURCE, "void BLENavigationServer::init(const char *deviceName)"
        )
        self.assertLess(
            init.index("ble_npl_event_init(&deferredNotificationEvent"),
            init.index("startHostHeartbeat()"),
        )
        # The transfer-status write callback takes the transfer server's state
        # lock on the host task: the wait, the holder and the holder's call
        # site are recorded, and the record never runs under the lock.
        http = (
            Path(__file__).resolve().parents[2]
            / "lib"
            / "device_transfer"
            / "device_transfer_http.cpp"
        ).read_text(encoding="utf-8")
        lock = function_body(
            http, "__attribute__((noinline)) void HttpTransferServer::lockState() const"
        )
        self.assertIn("xSemaphoreGetMutexHolder(stateMutex_)", lock)
        self.assertIn("__builtin_return_address(0)", lock)
        self.assertNotIn("recordStateLock(", lock)
        self.assertNotIn("ride_diagnostics::record(", lock)
        unlock = function_body(
            http,
            "__attribute__((noinline)) void HttpTransferServer::unlockState() const",
        )
        self.assertLess(
            unlock.index("xSemaphoreGive(stateMutex_)"),
            unlock.index("recordStateLock(false"),
        )
        self.assertLess(
            unlock.index("xSemaphoreGive(stateMutex_)"),
            unlock.index("recordStateLock(true"),
        )
        # Probe records are queued where they happen and written only by the
        # loop task: nothing enters the recorder on the host task, on the
        # esp_timer task or under a mutex.
        for signature in (
            "static void recordHostActivity(",
            "static void recordLockWait(",
            "static void recordHostHeartbeat(",
            "static void hostHeartbeatTimerHandler(",
            "static void hostHeartbeatEventHandler(",
        ):
            body = function_body(BLE_SOURCE, signature)
            self.assertNotIn("ride_diagnostics::record(", body, signature)
        for signature in (
            "static void recordHostActivity(",
            "static void recordLockWait(",
            "static void recordHostHeartbeat(",
        ):
            self.assertIn("queueProbeRecord(", function_body(BLE_SOURCE, signature))
        drain = function_body(BLE_SOURCE, "static void drainProbeRecords() {")
        self.assertIn("ride_diagnostics::record(", drain)
        process = function_body(BLE_SOURCE, "void BLENavigationServer::process()")
        self.assertIn("drainProbeRecords()", process)
        scope = BLE_SOURCE.split("class HostActivityScope {", 1)[1].split("\nclass ", 1)[0]
        self.assertIn("onNimbleHostTask()", scope)

    def test_chunked_map_status_resumes_after_each_host_drain(self):
        notify = function_body(
            BLE_SOURCE, "static void notifyMapTransferStatus"
        )
        self.assertIn("pendingMapTransferStatusChunks.begin", notify)
        self.assertIn("pumpPendingMapTransferStatusChunks()", notify)

        pump = function_body(
            BLE_SOURCE, "static void pumpPendingMapTransferStatusChunks() {"
        )
        self.assertIn("deferredNotificationAvailableCapacity()", pump)
        self.assertIn("notifyAuthenticatedNavigation", pump)
        self.assertIn("pendingMapTransferStatusChunks.advance()", pump)
        self.assertLess(
            pump.index("notifyAuthenticatedNavigation"),
            pump.index("pendingMapTransferStatusChunks.advance()"),
        )

        event_handler = function_body(
            BLE_SOURCE,
            "static void deferredNotificationEventHandler(struct ble_npl_event *event) {",
        )
        self.assertIn("pendingMapTransferStatusContinuation.load", event_handler)
        self.assertIn("ui_scheduler::notify(ui_scheduler::WakeReason::Ble)", event_handler)

        process = function_body(BLE_SOURCE, "void BLENavigationServer::process()")
        self.assertIn("pumpPendingMapTransferStatusChunks()", process)


if __name__ == "__main__":
    unittest.main()
