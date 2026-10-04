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
