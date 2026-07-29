from __future__ import annotations

import hashlib
import hmac
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlencode


class DownloadTokenError(ValueError):
    """Raised when a signed download URL token is invalid."""


@dataclass(frozen=True)
class SignedDownload:
    map_id: str
    path: Path
    expires_at: int
    signature: str

    def query(self) -> str:
        return urlencode({"expires": self.expires_at, "signature": self.signature})


class DownloadSigner:
    def __init__(self, secret: str):
        if not secret:
            raise ValueError("download signing secret must not be empty")
        self.secret = secret.encode("utf-8")

    def sign(self, map_id: str, path: str | Path, *, ttl_seconds: int = 900, now: int | None = None) -> SignedDownload:
        current = int(time.time()) if now is None else now
        expires_at = current + ttl_seconds
        resolved_path = Path(path)
        signature = self._signature(map_id, resolved_path, expires_at)
        return SignedDownload(map_id=map_id, path=resolved_path, expires_at=expires_at, signature=signature)

    def verify(self, map_id: str, path: str | Path, *, expires_at: int, signature: str, now: int | None = None) -> None:
        current = int(time.time()) if now is None else now
        if expires_at < current:
            raise DownloadTokenError("download URL has expired")
        expected = self._signature(map_id, Path(path), expires_at)
        if not hmac.compare_digest(expected, signature):
            raise DownloadTokenError("invalid download signature")

    def _signature(self, map_id: str, path: Path, expires_at: int) -> str:
        payload = f"{map_id}\n{path}\n{expires_at}".encode("utf-8")
        return hmac.new(self.secret, payload, hashlib.sha256).hexdigest()
