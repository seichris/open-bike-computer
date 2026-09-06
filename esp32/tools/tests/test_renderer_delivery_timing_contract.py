"""Source contracts for optional debug timing (not a physical timing test)."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
BLE = (ROOT / "esp32/lib/ble_navigation/ble_navigation.cpp").read_text()
DIAGNOSTICS = (ROOT / "esp32/lib/renderer_diagnostics/renderer_diagnostics.cpp").read_text()


class DeliveryTimingContractTests(unittest.TestCase):
    def test_native_callback_timing_encloses_mtu_query(self):
        for name in ("MyRouteCharacteristicCallbacks", "MyGPSCharacteristicCallbacks"):
            body = BLE.split("class " + name, 1)[1].split("\nclass ", 1)[0]
            self.assertLess(body.index("DeliveryCallbackScope timing"),
                            body.index("ScopedNimbleCallback callbackScope"))
            self.assertLess(body.index("timing.setupComplete()"),
                            body.index("unwrapOwnerAuthenticatedPayload"))
            self.assertIn("&timing", body)

    def test_timing_does_not_log_or_allocate(self):
        scope = BLE.split("class DeliveryCallbackScope", 1)[1].split(
            "static bool queueMapInput", 1)[0]
        self.assertIn("FIRMWARE_DIAGNOSTICS && defined(DEVICE_REMOTE_DEBUG) && DEVICE_REMOTE_DEBUG", scope)
        for forbidden in ("Serial.", "malloc(", "new ", "std::string"):
            self.assertNotIn(forbidden, scope)

    def test_metrics_copy_and_record_share_lock(self):
        body = DIAGNOSTICS.split("void completeDeliveryCallback", 1)[1].split(
            "void noteDeliveryOwner", 1)[0]
        self.assertLess(body.index("portENTER_CRITICAL"), body.index("deliveryTiming.complete"))
        self.assertLess(body.index("deliveryTiming.complete"), body.index("portEXIT_CRITICAL"))
        self.assertIn("value.deliveryTiming = deliveryTiming.snapshot();", DIAGNOSTICS)

    def test_incomplete_progress_is_published_without_payload(self):
        body = DIAGNOSTICS.split("void noteDeliveryCallbackProgress", 1)[1].split(
            "void completeDeliveryCallback", 1)[0]
        self.assertLess(body.index("portENTER_CRITICAL"), body.index("deliveryTiming.progress"))
        self.assertLess(body.index("deliveryTiming.progress"), body.index("portEXIT_CRITICAL"))
        for phase in ("Authenticating", "AuthenticationFinished", "Allocating",
                      "WaitingForMailbox", "HoldingMailbox", "Dispatching"):
            self.assertIn("DeliveryCallbackPhase::" + phase, BLE)
        self.assertIn("value.deliveryTiming.latestStarted.phase", DIAGNOSTICS)
        self.assertIn("value.deliveryTiming.started", DIAGNOSTICS)


if __name__ == "__main__":
    unittest.main()
