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

        send = function_body(BLE_SOURCE, "static bool sendWireNotification")
        self.assertIn("server->getPeerMTU", send)
        self.assertIn("characteristic->notify()", send)

        for producer in (
            function_body(BLE_SOURCE, "static void notifyMapTransferStatus"),
            function_body(
                BLE_SOURCE, "static void notifyRendererDiagnosticsStatus"
            ),
        ):
            self.assertNotIn("getPeerMTU", producer)
            self.assertIn("activePeerMtu.load", producer)

    def test_arduino_loop_does_not_drain_deferred_transport(self):
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


if __name__ == "__main__":
    unittest.main()
