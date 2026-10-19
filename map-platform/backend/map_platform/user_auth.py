"""Person authentication, deliberately independent of installation credentials."""
from __future__ import annotations

from dataclasses import dataclass
from collections import OrderedDict
from threading import Event, Lock
import time


@dataclass(frozen=True)
class AccountPrincipal:
    project: str
    uid: str
    authenticated_at: int

    def require_recent(self, now: float | None = None) -> None:
        age = (time.time() if now is None else now) - self.authenticated_at
        if not -60 <= age <= 300:
            raise ValueError("reauthentication_required")


class IdentityUnavailable(RuntimeError):
    """The identity provider could not answer. This is never evidence of revocation."""


class _RevocationLookup:
    """One provider lookup shared by every concurrent request for the same UID."""
    __slots__ = ("done", "state", "failure")

    def __init__(self):
        self.done = Event()
        self.state: tuple[float, bool, float] | None = None
        self.failure: str | None = None


class FirebaseIdentity:
    # Provider calls are bounded so a slow lookup cannot hold request threads for
    # firebase-admin's 120-second default. Revocation state is cached briefly;
    # SQL account, block and consent authorization is still checked per request.
    HTTP_TIMEOUT_SECONDS = 5
    REVOCATION_TTL_SECONDS = 30
    CACHE_CAPACITY = 512
    LOOKUP_CAPACITY = 64
    LOOKUP_WAIT_SECONDS = 8.0

    def __init__(self, project: str, *, clock=time.monotonic, http_timeout: float = HTTP_TIMEOUT_SECONDS,
                 lookup_wait: float = LOOKUP_WAIT_SECONDS, lookup_capacity: int = LOOKUP_CAPACITY,
                 cache_capacity: int = CACHE_CAPACITY):
        if not project:
            raise ValueError("BICINO_FIREBASE_PROJECT_ID is required")
        import firebase_admin
        self.project = project
        self.clock = clock
        self.lookup_wait = lookup_wait
        self.lookup_capacity = lookup_capacity
        self.cache_capacity = cache_capacity
        self._revocation: OrderedDict[str, tuple[float, bool, float]] = OrderedDict()
        self._lookups: dict[str, _RevocationLookup] = {}
        # Guards only the cache and in-flight table. Provider I/O never runs under it.
        self._lock = Lock()
        # Application Default Credentials; never accept credentials from a caller.
        try:
            self.app = firebase_admin.get_app("bicino-social")
        except ValueError:
            self.app = firebase_admin.initialize_app(
                options={"projectId": project, "httpTimeout": http_timeout}, name="bicino-social"
            )
        if self.app.project_id != project:
            raise ValueError("Firebase project mismatch")

    def verify(self, token: str) -> AccountPrincipal:
        from firebase_admin import auth
        if not 100 <= len(token) <= 10000:
            raise ValueError("invalid_token")
        # Signature, issuer, audience and expiry are verified on every request.
        try:
            claims = auth.verify_id_token(token, app=self.app, check_revoked=False)
        except auth.CertificateFetchError:
            raise IdentityUnavailable("certificate_fetch") from None
        uid = claims["uid"]
        disabled, valid_after = self._revocation_state(uid)
        if disabled or claims["auth_time"] < valid_after:
            raise ValueError("revoked_token")
        return AccountPrincipal(self.project, uid, int(claims["auth_time"]))

    def _revocation_state(self, uid: str) -> tuple[bool, float]:
        from firebase_admin import auth
        with self._lock:
            cached = self._revocation.get(uid)
            if cached is not None and 0 <= self.clock()-cached[0] < self.REVOCATION_TTL_SECONDS:
                self._revocation.move_to_end(uid)
                return cached[1], cached[2]
            lookup = self._lookups.get(uid)
            owner = lookup is None
            if owner:
                if len(self._lookups) >= self.lookup_capacity:
                    raise IdentityUnavailable("revocation_capacity")
                lookup = self._lookups[uid] = _RevocationLookup()
        if owner:
            try:
                user = auth.get_user(uid, app=self.app)
                lookup.state = (self.clock(), bool(user.disabled), user.tokens_valid_after_timestamp / 1000)
            except auth.UserNotFoundError:
                lookup.failure = "revoked"
            except Exception:
                # Network, quota, timeout or provider faults are an outage, not revocation.
                lookup.failure = "unavailable"
            finally:
                with self._lock:
                    self._lookups.pop(uid, None)
                    if lookup.state is not None:
                        self._revocation[uid] = lookup.state
                        self._revocation.move_to_end(uid)
                        while len(self._revocation) > self.cache_capacity:
                            self._revocation.popitem(last=False)
                lookup.done.set()
        elif not lookup.done.wait(self.lookup_wait):
            raise IdentityUnavailable("revocation_lookup_timeout")
        if lookup.failure == "revoked":
            raise ValueError("revoked_token")
        if lookup.state is None:
            raise IdentityUnavailable("revocation_lookup_failed")
        return lookup.state[1], lookup.state[2]

    def status(self, uid: str) -> str:
        from firebase_admin import auth
        try:
            return "disabled" if auth.get_user(uid, app=self.app).disabled else "active"
        except auth.UserNotFoundError:
            return "deleted"

    def delete(self, uid: str) -> None:
        from firebase_admin import auth
        try:
            auth.delete_user(uid, app=self.app)
        except auth.UserNotFoundError:
            pass

    def revoke_apple(self, uid: str, code: str | None) -> None:
        """Verify the Apple grant belongs to this Firebase account before revoking."""
        import os
        import httpx
        import jwt
        from firebase_admin import auth
        from .social.service import SocialError
        user = auth.get_user(uid, app=self.app)
        apple = next((p for p in user.provider_data if p.provider_id == "apple.com"), None)
        if apple is None:
            return
        if not code:
            raise SocialError("apple_reauthentication_required", 401)
        client_id = os.environ["BICINO_APPLE_NATIVE_CLIENT_ID"]
        secret = jwt.encode({"iss": os.environ["BICINO_APPLE_TEAM_ID"], "iat": int(time.time()),
            "exp": int(time.time())+300, "aud": "https://appleid.apple.com", "sub": client_id},
            os.environ["BICINO_APPLE_PRIVATE_KEY"].replace("\\n", "\n"), algorithm="ES256",
            headers={"kid": os.environ["BICINO_APPLE_KEY_ID"]})
        with httpx.Client(timeout=10) as client:
            token = client.post("https://appleid.apple.com/auth/token", data={"client_id": client_id,
                "client_secret": secret, "code": code, "grant_type": "authorization_code"})
            if token.status_code != 200:
                raise SocialError("apple_reauthentication_required", 401)
            result = token.json()
            key = jwt.PyJWKClient("https://appleid.apple.com/auth/keys", timeout=10).get_signing_key_from_jwt(result["id_token"])
            claims = jwt.decode(result["id_token"], key.key, algorithms=["RS256"],
                                audience=client_id, issuer="https://appleid.apple.com")
            if claims["sub"] != apple.uid:
                raise SocialError("account_changed", 409)
            response = client.post("https://appleid.apple.com/auth/revoke", data={"client_id": client_id,
                "client_secret": secret, "token": result["refresh_token"], "token_type_hint": "refresh_token"})
            if response.status_code != 200:
                raise SocialError("apple_revocation_unavailable", 503)
