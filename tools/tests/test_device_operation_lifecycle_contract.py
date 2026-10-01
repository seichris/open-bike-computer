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
        self.assertIn("stored.deviceID == deviceID", begin)
        self.assertIn("stored.mode == bleManager.deviceTransferMode", begin)
        self.assertIn("coordinator.transferGeneration == bleManager.deviceTransferGeneration", begin)
        self.assertIn("coordinator.tokenDigest == Self.authorizationDigest(token)", begin)
        self.assertIn("deviceTransferStatusRevision != revision", begin)
        self.assertLess(begin.index("coordinator.tokenDigest =="), begin.index("coordinator.adoptUnresolved("))
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

    def test_debug_owner_outlives_view_recreation(self):
        section = SETTINGS[SETTINGS.index("private struct RemoteDeviceDebugSettingsSection"):]
        self.assertIn("static let sharedTransferManager = DeviceTransferManager()", section)
        self.assertIn("remoteDebugTransferManager.enterRemoteDebug", section)
        self.assertIn("remoteDebugTransferManager.exitRemoteDebug", section)
        self.assertNotIn("DeviceTransferManager().exitRemoteDebug", section)


if __name__ == "__main__":
    unittest.main()
