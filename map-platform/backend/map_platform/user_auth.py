"""Person authentication, deliberately independent of installation credentials."""
from __future__ import annotations

from dataclasses import dataclass
import time


@dataclass(frozen=True)
class AccountPrincipal:
    project: str
    uid: str
    authenticated_at: int

    def require_recent(self, now: float | None = None) -> None:
        age = (time.time() if now is None else now) - self.authenticated_at
        if not 0 <= age <= 300:
            raise ValueError("reauthentication_required")


class FirebaseIdentity:
    def __init__(self, project: str):
        if not project:
            raise ValueError("BICINO_FIREBASE_PROJECT_ID is required")
        import firebase_admin
        self.project = project
        # Application Default Credentials; never accept credentials from a caller.
        try:
            self.app = firebase_admin.get_app("bicino-social")
        except ValueError:
            self.app = firebase_admin.initialize_app(
                options={"projectId": project}, name="bicino-social"
            )
        if self.app.project_id != project:
            raise ValueError("Firebase project mismatch")

    def verify(self, token: str) -> AccountPrincipal:
        from firebase_admin import auth
        if not 100 <= len(token) <= 10000:
            raise ValueError("invalid_token")
        claims = auth.verify_id_token(token, app=self.app, check_revoked=True)
        return AccountPrincipal(self.project, claims["uid"], int(claims["auth_time"]))

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
