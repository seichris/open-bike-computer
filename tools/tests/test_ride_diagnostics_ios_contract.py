from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
DIAGNOSTICS_MANAGER = (
    REPO_ROOT
    / "ios-app/BikeComputer/BikeComputer/Managers/DeviceDiagnosticsTransferManager.swift"
).read_text(encoding="utf-8")
TRANSFER_MANAGER = (
    REPO_ROOT
    / "ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift"
).read_text(encoding="utf-8")
NAV_SCRIPT = (
    REPO_ROOT / "ios-app/scripts/run-navigation-tests.sh"
).read_text(encoding="utf-8")


class RideDiagnosticsIOSContractTests(unittest.TestCase):
    def test_download_flow_owns_enter_download_health_and_exit(self):
        flow = DIAGNOSTICS_MANAGER[
            DIAGNOSTICS_MANAGER.index("func downloadDeviceLogs") :
            DIAGNOSTICS_MANAGER.index("private func closeSession")
        ]
        self.assertIn("enterDiagnostics(", flow)
        self.assertIn("device-diagnostics/v1/index", flow)
        self.assertIn("importDeviceChunkAsync", flow)
        self.assertIn("importDeviceRecorderHealthAsync", flow)
        self.assertIn("closeSession(session, bleManager: bleManager)", flow)
        self.assertIn("enforceRetentionAsync", flow)

    def test_session_controller_has_authenticated_exit_and_network_cleanup(self):
        enter = TRANSFER_MANAGER[
            TRANSFER_MANAGER.index("func enterDiagnostics") :
            TRANSFER_MANAGER.index("private func waitForDiagnosticsSession")
        ]
        exit_flow = TRANSFER_MANAGER[
            TRANSFER_MANAGER.index("func exitDiagnostics") :
            TRANSFER_MANAGER.index("func enterRemoteDebug")
        ]
        self.assertIn("requestDeviceTransferMode(\n                .diagnostics", enter)
        self.assertIn("joinDeviceNetworkIfNeeded", enter)
        self.assertIn("exitDiagnostics(bleManager: bleManager)", enter)
        self.assertIn("requestDeviceTransferExit()", TRANSFER_MANAGER)
        self.assertIn("removeJoinedAccessPointIfNeeded()", exit_flow)

    def test_navigation_host_harness_compiles_the_transfer_managers(self):
        self.assertIn("Managers/DeviceTransferManager.swift", NAV_SCRIPT)
        self.assertIn("Managers/DeviceDiagnosticsTransferManager.swift", NAV_SCRIPT)


if __name__ == "__main__":
    unittest.main()
