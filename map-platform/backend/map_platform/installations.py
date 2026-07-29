from __future__ import annotations

import base64
import hashlib
import hmac
import re
import secrets
import uuid


INSTALLATION_ID_PREFIX = "inst_v2_"
INSTALLATION_TOKEN_VERSION = "v1"


class InstallationCredentialError(ValueError):
    pass


class InstallationCredentialStore:
    """Stateless server-issued credentials for installation-owned resources."""

    def __init__(self, current_secret: str, *, previous_secrets: list[str] | None = None):
        if len(current_secret.encode("utf-8")) < 32:
            raise ValueError("installation credential secret must be at least 32 bytes")
        secrets_to_accept = [current_secret, *(previous_secrets or [])]
        if any(len(value.encode("utf-8")) < 32 for value in secrets_to_accept):
            raise ValueError("installation credential secrets must be at least 32 bytes")
        self._secrets = [value.encode("utf-8") for value in secrets_to_accept]

    def issue(self) -> tuple[str, str]:
        installation_id = f"{INSTALLATION_ID_PREFIX}{uuid.uuid4().hex}"
        return installation_id, self._token(installation_id, self._secrets[0])

    def refresh(self, installation_id: str, token: str | None) -> tuple[str, str]:
        """Exchange any accepted installation token for one using the current secret."""
        self.verify(installation_id, token)
        return installation_id, self._token(installation_id, self._secrets[0])

    def is_registered(self, installation_id: str) -> bool:
        return bool(
            isinstance(installation_id, str)
            and re.fullmatch(rf"{INSTALLATION_ID_PREFIX}[0-9a-f]{{32}}", installation_id)
        )

    def verify(self, installation_id: str, token: str | None) -> None:
        if not self.is_registered(installation_id) or not token:
            raise InstallationCredentialError("installation credential is required")
        if not any(
            secrets.compare_digest(self._token(installation_id, key), token)
            for key in self._secrets
        ):
            raise InstallationCredentialError("installation credential is invalid")

    @staticmethod
    def _token(installation_id: str, key: bytes) -> str:
        signature = hmac.new(
            key,
            f"open-bike-installation-v1\0{installation_id}".encode("utf-8"),
            hashlib.sha256,
        ).digest()
        encoded = base64.urlsafe_b64encode(signature).rstrip(b"=").decode("ascii")
        return f"{INSTALLATION_TOKEN_VERSION}.{encoded}"
