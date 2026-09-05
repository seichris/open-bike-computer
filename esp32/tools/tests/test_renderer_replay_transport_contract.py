"""Source contract for the native GPS transport shared by both ATT write modes."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]
BLE = (ROOT / "esp32/lib/ble_navigation/ble_navigation.cpp").read_text()
IOS = (ROOT / "ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift").read_text()


class RendererReplayTransportContractTests(unittest.TestCase):
    def test_both_att_modes_use_the_same_gps_callback(self):
        self.assertRegex(BLE, re.compile(
            r"pGPSCharacteristic\s*=\s*pService->createCharacteristic\(\s*"
            r"GPS_CHAR_UUID, NIMBLE_PROPERTY::WRITE \| NIMBLE_PROPERTY::WRITE_NR\);"
            r"\s*pGPSCharacteristic->setCallbacks\(new MyGPSCharacteristicCallbacks\(\)\);"
        ))
        callback = BLE.split("class MyGPSCharacteristicCallbacks", 1)[1].split(
            "class ", 1
        )[0]
        self.assertLess(callback.index("unwrapOwnerAuthenticatedPayload"),
                        callback.index("dispatchReplaySample"))
        self.assertLess(callback.index("bleSessionSupportsRendererBenchmarkSample"),
                        callback.index("dispatchReplaySample"))
        self.assertLess(callback.index("queueMapInput"),
                        callback.index("noteRouteMarker"))

    def test_ios_uses_native_routing_and_never_navigation_fallback(self):
        sample = IOS.split("func sendRendererBenchmarkSample(", 1)[1].split(
            "func sendRendererBenchmarkMarker(", 1
        )[0]
        self.assertIn("GPSPositionWriteRouting.route(", sample)
        self.assertIn("case .nativeWithResponse: writeType = .withResponse", sample)
        self.assertIn("case .nativeWithoutResponse: writeType = .withoutResponse", sample)
        self.assertRegex(sample, r"case \.navigationFallback:\s*//[^\n]*\n\s*return false")
        self.assertIn("transportExpectsWriteResponse: expectsWriteResponse", sample)
        self.assertIn("transportCharacteristicUUIDString: characteristic.uuid.uuidString", sample)
        self.assertNotIn("sendFallback", sample)


if __name__ == "__main__":
    unittest.main()
