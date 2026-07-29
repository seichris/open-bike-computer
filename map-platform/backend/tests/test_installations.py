import unittest

from map_platform.installations import (
    InstallationCredentialError,
    InstallationCredentialStore,
)


class InstallationCredentialTests(unittest.TestCase):
    def test_credentials_are_stateless_unforgeable_and_rotation_compatible(self):
        old_secret = "old-installation-secret-at-least-32-bytes"
        new_secret = "new-installation-secret-at-least-32-bytes"
        old_store = InstallationCredentialStore(old_secret)
        installation_id, token = old_store.issue()
        old_store.verify(installation_id, token)

        rotated = InstallationCredentialStore(
            new_secret,
            previous_secrets=[old_secret],
        )
        rotated.verify(installation_id, token)
        refreshed_id, refreshed_token = rotated.refresh(installation_id, token)
        self.assertEqual(refreshed_id, installation_id)
        self.assertNotEqual(refreshed_token, token)
        InstallationCredentialStore(new_secret).verify(
            refreshed_id,
            refreshed_token,
        )
        with self.assertRaises(InstallationCredentialError):
            InstallationCredentialStore(new_secret).verify(installation_id, token)
        with self.assertRaises(InstallationCredentialError):
            rotated.verify(installation_id, token + "tampered")
        with self.assertRaises(InstallationCredentialError):
            rotated.verify("installation-owner", token)


if __name__ == "__main__":
    unittest.main()
