"""The iOS OTA slot model and Pages channels follow esp32/partition_layouts.json."""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import firmware_ota_channels  # noqa: E402
import web_flasher_manifest  # noqa: E402

SWIFT = ROOT / "ios-app/BikeComputer/BikeComputer/Managers/FirmwareUpdateManager.swift"


def swift_int(source: str, name: str) -> int:
    match = re.search(rf"static let {name} = ([0-9_]+)\n", source)
    if match is None:
        raise AssertionError(f"FirmwareSlotLayout.{name} is missing")
    return int(match.group(1).replace("_", ""))


class FirmwareSlotContractTests(unittest.TestCase):
    def test_ios_slot_constants_match_the_registry(self):
        source = SWIFT.read_text(encoding="utf-8")
        layouts = firmware_ota_channels.LAYOUTS
        legacy = layouts.legacy("production")
        current = layouts.current("production")
        self.assertEqual(swift_int(source, "applicationReserveBytes"),
                         legacy.application_slots[0].size - legacy.max_application_bytes)
        self.assertEqual(swift_int(source, "legacySlotBytes"), legacy.application_slots[0].size)
        self.assertEqual(swift_int(source, "currentSlotBytes"), current.application_slots[0].size)
        self.assertIn(f'pathComponent: "{firmware_ota_channels.CURRENT_CHANNEL}"', source)
        self.assertEqual(firmware_ota_channels.CURRENT_CHANNEL, "dual4m")
        self.assertEqual(web_flasher_manifest.short_name(current), firmware_ota_channels.CURRENT_CHANNEL)
        self.assertIn("static let maximumImageBytes = FirmwareSlotLayout.currentSlotBytes", source)
        self.assertNotIn("3 * 1024 * 1024", source)

    def test_installer_checks_fresh_slot_capacity_before_any_write(self):
        source = SWIFT.read_text(encoding="utf-8")
        install = source[source.index("    func installLatest(bleManager: BLEManager) {"):
                         source.index("    func refreshDeviceFirmwareStatus(")]
        eligibility = install.index("requireFirmwareMaintenanceEligibility(")
        ble_fit = install.index("try Self.requireImageFits(manifest, capacity: Self.deviceCapacity(bleManager))")
        self.assertLess(eligibility, ble_fit)
        self.assertLess(ble_fit, install.index("beginFirmwareMaintenanceReconnect()"))
        self.assertLess(ble_fit, install.index("self.downloadFirmware(manifest: manifest)"))
        status = install.index("let initialDeviceStatus = try await client.status()")
        http_fit = install.index("try Self.requireImageFits(manifest, capacity: FirmwareSlotLayout.capacity(")
        self.assertLess(status, http_fit)
        self.assertLess(http_fit, install.index("client.begin(manifest: manifest"))
        # A retained earlier result is acknowledged regardless of this image.
        self.assertLess(install.index("client.acknowledge("), http_fit)
        self.assertIn("eligibilityCode: initialDeviceStatus.eligibilityCode", install)


if __name__ == "__main__":
    unittest.main()
