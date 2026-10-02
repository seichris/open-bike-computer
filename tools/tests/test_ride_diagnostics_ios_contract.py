from pathlib import Path
import unittest
import json


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
        registry = json.loads((REPO_ROOT / "tools/development/swift-sources.json").read_text())
        import importlib.util
        spec = importlib.util.spec_from_file_location("swift_sources", REPO_ROOT / "tools/development/swift_compile.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        files = module.sources("navigation-5", registry["groups"])
        self.assertIn("ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift", files)
        self.assertIn("ios-app/BikeComputer/BikeComputer/Managers/DeviceDiagnosticsTransferManager.swift", files)


if __name__ == "__main__":
    unittest.main()
