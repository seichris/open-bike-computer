import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
BLE_CPP = REPO_ROOT / "esp32/lib/ble_navigation/ble_navigation.cpp"
BLE_HPP = REPO_ROOT / "esp32/lib/ble_navigation/ble_navigation.hpp"
MAIN_CPP = REPO_ROOT / "esp32/src/main.cpp"


class FirmwareMaintenanceBleContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ble_cpp = BLE_CPP.read_text(encoding="utf-8")
        cls.ble_hpp = BLE_HPP.read_text(encoding="utf-8")
        cls.main_cpp = MAIN_CPP.read_text(encoding="utf-8")

    def test_authentication_timeout_uses_live_ble_state(self):
        self.assertIn("bool isAuthenticated() const;", self.ble_hpp)
        self.assertRegex(
            self.main_cpp,
            r"authenticationTimedOut\(\s*maintenanceElapsed,\s*"
            r"bleNavServer\.isAuthenticated\(\)\)",
        )
        self.assertNotRegex(
            self.main_cpp,
            r"authenticationTimedOut\(\s*maintenanceElapsed,\s*false\)",
        )

    def test_native_and_fallback_channels_share_maintenance_dispatch(self):
        self.assertEqual(
            self.ble_cpp.count("handleFirmwareMaintenancePayload("),
            3,
            "the helper definition plus Navigation and Settings callsites are required",
        )
        settings_start = self.ble_cpp.index("class MySettingsCharacteristicCallbacks")
        settings_end = self.ble_cpp.index(
            "class MyAuthCharacteristicCallbacks", settings_start
        )
        settings_callback = self.ble_cpp[settings_start:settings_end]
        maintenance_dispatch = settings_callback.index(
            "handleFirmwareMaintenancePayload("
        )
        normal_settings_dispatch = settings_callback.index(
            "ride_automation_protocol::FALLBACK_PREFIX_SIZE"
        )
        self.assertLess(maintenance_dispatch, normal_settings_dispatch)

    def test_maintenance_preserves_gatt_prefix_through_settings(self):
        init_start = self.ble_cpp.index("void BLENavigationServer::init(")
        service_start = self.ble_cpp.index(
            "NimBLEService *pService = pServer->createService", init_start
        )
        normal_only_start = self.ble_cpp.index(
            "if (!maintenanceBoot) {\n    // Workout frames", service_start
        )
        stable_prefix = self.ble_cpp[service_start:normal_only_start]

        ordered_uuids = [
            "NAV_CHAR_UUID",
            "AUTH_CHAR_UUID",
            "ROUTE_CHAR_UUID",
            "GPS_CHAR_UUID",
            "SETTINGS_CHAR_UUID",
        ]
        positions = [stable_prefix.index(uuid) for uuid in ordered_uuids]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("MyMaintenanceRejectedCharacteristicCallbacks", stable_prefix)
        self.assertIn("new MySettingsCharacteristicCallbacks()", stable_prefix)

    def test_firmware_transfer_survives_wifi_startup_ble_reconnect(self):
        disconnect_start = self.ble_cpp.index("void disconnectActive()")
        disconnect_end = self.ble_cpp.index(
            "class MyNavCharacteristicCallbacks", disconnect_start
        )
        disconnect = self.ble_cpp[disconnect_start:disconnect_end]
        self.assertIn("suspendAuthenticatedBleSession()", disconnect)
        self.assertIn("!suspendedFirmwareTransfer", disconnect)

        maintenance_start = self.ble_cpp.index(
            "static bool handleFirmwareMaintenancePayload("
        )
        maintenance_end = self.ble_cpp.index(
            "class MyMaintenanceRejectedCharacteristicCallbacks",
            maintenance_start,
        )
        maintenance = self.ble_cpp[maintenance_start:maintenance_end]
        self.assertIn("bindAuthenticatedBleSession(", maintenance)
        self.assertIn("currentAuthenticatedTransferSessionId()", maintenance)
        self.assertLess(
            maintenance.index("bindAuthenticatedBleSession("),
            maintenance.index("queueTransferControl(ble_transfer::Action::None"),
        )


if __name__ == "__main__":
    unittest.main()
