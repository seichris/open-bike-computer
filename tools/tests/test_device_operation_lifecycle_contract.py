"""Integration wiring contracts; executable scheduling cases live in Swift harness."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "ios-app/BikeComputer/BikeComputer"
MANAGER = (APP / "Managers/DeviceTransferManager.swift").read_text()
REGISTRY = (APP / "Managers/DeviceOperationCoordinator.swift").read_text()
BACKGROUND = (APP / "Models/OfflineMapPlatform.swift").read_text()
SETTINGS = (APP / "Views/SettingsView.swift").read_text()


class DeviceOperationLifecycleContractTests(unittest.TestCase):
    def test_reconnect_cleanup_requires_fresh_exact_authorization(self):
        begin = MANAGER[MANAGER.index("private func beginOperation"):MANAGER.index("private static func authorizationDigest")]
        self.assertIn("bleManager.isNavigationReady", begin)
        self.assertIn("try await coordinator.recover(", begin)
        self.assertIn("let deviceID = bleManager.connectedDeviceID", begin)
        for field in ("deviceID: deviceID",
                      "connectionEpoch: bleManager.transferConnectionEpoch",
                      "status: { Self.recoveryStatus(bleManager) }",
                      "requestStatus: { bleManager.requestDeviceTransferStatus() }"):
            self.assertIn(field, begin)
        self.assertLess(begin.index("let deviceID = bleManager.connectedDeviceID"),
                        begin.index("coordinator.recover("))
        status = MANAGER[MANAGER.index("private static func recoveryStatus("):MANAGER.index("private func ownsConnection(")]
        for field in ("deviceID: bleManager.connectedDeviceID",
                      "connectionEpoch: bleManager.transferConnectionEpoch",
                      "ready: bleManager.isNavigationReady",
                      "revision: bleManager.deviceTransferStatusRevision",
                      "mode: bleManager.deviceTransferMode",
                      "Self.authorizationDigest($0)",
                      "transferGeneration: bleManager.deviceTransferGeneration"):
            self.assertIn(field, status)
        self.assertLess(begin.index("coordinator.recover("), begin.index("coordinator.acquire("))
        recovery = REGISTRY[REGISTRY.index("func recover("):REGISTRY.index("init(defaults:")]
        for fence in ("stored.deviceID == deviceID", "current.deviceID == deviceID",
                      "current.connectionEpoch == connectionEpoch", "current.ready",
                      "current.revision != revision", "current.mode == stored.mode",
                      "current.tokenDigest == tokenDigest",
                      "current.transferGeneration == transferGeneration"):
            self.assertIn(fence, recovery)
        self.assertLess(recovery.index("current.tokenDigest == tokenDigest"),
                        recovery.index("adoptUnresolved("))
        self.assertNotIn("coordinator.adoptUnresolved(", begin)
        self.assertIn("SHA256.hash(data: Data(token.utf8))", MANAGER)
        record = REGISTRY[REGISTRY.index("private struct CleanupRecord"):REGISTRY.index("static let shared")]
        self.assertIn("tokenDigest", record)
        self.assertNotIn("sessionToken", record)

    def test_background_restore_is_identity_bound_and_completion_fenced(self):
        restore = BACKGROUND[BACKGROUND.index("func restorePersistedTasks()"):BACKGROUND.index("func activeUploadActivity()")]
        self.assertIn("descriptor.hasDurableIdentity", restore)
        self.assertIn("descriptor.appNamespace == Self.sessionIdentifier", restore)
        self.assertIn("DeviceTransferManager.restoreNetworkClaim(", restore)
        self.assertIn("!self.installRestoredClaim(claim, for: task)", restore)
        self.assertIn("DeviceTransferManager.releaseNetworkClaim(claim)", restore)
        install = BACKGROUND[BACKGROUND.index("private func installRestoredClaim"):BACKGROUND.index("func restorePersistedTasks()")]
        self.assertIn("!completedTaskIDs.contains(task.taskIdentifier)", install)
        self.assertIn("networkClaims[task.taskIdentifier] == nil", install)
        completion = BACKGROUND[BACKGROUND.index("didCompleteWithError error: Error?"):]
        self.assertIn("completedTaskIDs.insert(task.taskIdentifier)", completion)
        self.assertNotIn("removeAccessoryNetworkConfiguration", completion)

    def test_precommit_transport_recovery_requires_fresh_captured_context(self):
        resume = MANAGER[MANAGER.index("func resumeMapTransfer("):MANAGER.index("private func performEnterMapTransfer(")]
        self.assertIn("verifiedPrecommitRecovery: Bool = false", resume)
        self.assertIn("recoveryDeviceID == deviceID", resume)
        self.assertIn("recoveryConnectionEpoch == epoch", resume)
        self.assertIn("bleManager.transferConnectionEpoch == epoch", resume)
        self.assertIn("bleManager.deviceTransferStatusRevision != revision", resume)
        self.assertIn("bleManager.deviceTransferMode.isEmpty", resume)
        self.assertIn("bleManager.deviceTransferSessionToken?.isEmpty != false", resume)
        self.assertIn("coordinator.retireStoppedMapForPrecommitRecovery", resume)
        self.assertIn("expectedConnectionEpoch: epoch", resume)
        self.assertIn("operationLease?.connectionEpoch == expectedConnectionEpoch", resume)
        self.assertIn("guard let lease = operationLease else { return coordinator.isCleanupComplete }", MANAGER)

    def test_debug_exit_fixture_waits_for_its_enter_command(self):
        tests = (ROOT / "ios-app/BikeComputerTests/NavigationProtocolRideTests.swift").read_text()
        fixture = tests[tests.index("static func testDeviceTransferManagerConfirmsDebugExit()"):tests.index("static func testDeviceTransferManagerCompensatesCancelledDebugEntry()")]
        self.assertLess(fixture.index("handleDeviceCapabilitiesNotification("), fixture.index("installNavigationWriteEndpoint("))
        self.assertIn('!sentPackets.contains(Data("DTRNenter|debug".utf8))', fixture)
        self.assertLess(fixture.index('!sentPackets.contains(Data("DTRNenter|debug".utf8))'), fixture.index("let activeStatus"))
        self.assertNotIn("where sentPackets.isEmpty", fixture)

    def test_debug_owner_outlives_view_recreation(self):
        section = SETTINGS[SETTINGS.index("private struct RemoteDeviceDebugSettingsSection"):]
        self.assertIn("static let sharedTransferManager = DeviceTransferManager()", section)
        self.assertIn("remoteDebugTransferManager.enterRemoteDebug", section)
        self.assertIn("remoteDebugTransferManager.exitRemoteDebug", section)
        self.assertNotIn("DeviceTransferManager().exitRemoteDebug", section)


if __name__ == "__main__":
    unittest.main()
