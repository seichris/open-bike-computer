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
        self.assertIn("await cleanupOperation(bleManager: bleManager)", exit_flow)
        self.assertIn("Failure.cleanupUnresolved", exit_flow)
        self.assertNotIn("removeConfiguration", exit_flow)
        cleanup = TRANSFER_MANAGER[
            TRANSFER_MANAGER.index("private func cleanupOperation") :
            TRANSFER_MANAGER.index("func releaseFirmwareAfterReboot")
        ]
        self.assertIn("DeviceOperationCleanupTask.start", cleanup)
        self.assertIn("self.ownsConnection(bleManager)", cleanup)
        self.assertIn("deviceTransferSessionToken == self.authorizationToken", cleanup)
        self.assertIn("deviceTransferGeneration == self.authorizationGeneration", cleanup)
        self.assertIn("deviceTransferStatusRevision != revision", cleanup)
        self.assertIn("deviceTransferMode.isEmpty", cleanup)
        self.assertIn("deviceTransferSessionToken?.isEmpty != false", cleanup)
        self.assertLess(cleanup.index("requestDeviceTransferExit()"),
                        cleanup.index("self.coordinator.finish(lease, remoteClear: clear)"))
        registry = (REPO_ROOT / "ios-app/BikeComputer/BikeComputer/Managers/DeviceOperationCoordinator.swift").read_text()
        final_release = registry[registry.index("private func finishIfUnused"):]
        self.assertIn("guard claims.isEmpty, pendingApplies.isEmpty", final_release)
        self.assertLess(final_release.index("guard claims.isEmpty"),
                        final_release.index("removeConfiguration(ssid)"))

    def test_all_consumers_share_acquisition_wide_cleanup(self):
        for mode in ("MapTransfer", "FirmwareTransfer", "Diagnostics", "RemoteDebug"):
            entry = TRANSFER_MANAGER[
                TRANSFER_MANAGER.index(f"func enter{mode}(") :
                TRANSFER_MANAGER.index(f"private func performEnter{mode}(")
            ]
            self.assertIn("beginOperation(", entry, mode)
            self.assertIn("try Task.checkCancellation()", entry, mode)
            self.assertIn("guard ownsConnection(bleManager)", entry, mode)
            self.assertIn("session.operationLeaseID = operationLease?.id", entry, mode)
            self.assertIn("await cleanupOperation(bleManager: bleManager)", entry, mode)
        begin = TRANSFER_MANAGER[
            TRANSFER_MANAGER.index("private func beginOperation") :
            TRANSFER_MANAGER.index("private func ownsConnection")
        ]
        self.assertIn("operationLease == nil, cleanupTask == nil", begin)
        self.assertIn("coordinator.reconcileClear(deviceID: deviceID)", begin)
        cleanup = TRANSFER_MANAGER[
            TRANSFER_MANAGER.index("private func cleanupOperation") :
            TRANSFER_MANAGER.index("func releaseFirmwareAfterReboot")
        ]
        self.assertIn("if let cleanupTask { return await cleanupTask.value }", cleanup)
        self.assertIn("let commandSent = alreadyClear", cleanup)
        self.assertIn("? bleManager.requestDeviceTransferStatus()", cleanup)

    def test_navigation_host_harness_compiles_the_transfer_managers(self):
        self.assertIn("Managers/DeviceTransferManager.swift", NAV_SCRIPT)
        self.assertIn("Managers/DeviceDiagnosticsTransferManager.swift", NAV_SCRIPT)


if __name__ == "__main__":
    unittest.main()
