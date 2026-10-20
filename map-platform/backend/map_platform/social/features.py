"""Fail-closed rollout controls, shared by HTTP, links and live sockets."""
from dataclasses import asdict, dataclass
import os

from .service import SocialError


@dataclass(frozen=True)
class SocialFeatures:
    media: bool = False
    routes: bool = False
    activities: bool = False
    groups: bool = False
    hardware: bool = False
    invitePreviews: bool = False

    @classmethod
    def from_environment(cls):
        values = {}
        for name in cls.__dataclass_fields__:
            env_name = "INVITE_PREVIEWS" if name == "invitePreviews" else name.upper()
            raw = os.environ.get("BICINO_SOCIAL_FEATURE_" + env_name, "false").lower()
            if raw not in {"true", "false"}:
                raise ValueError("Social feature flags must be true or false")
            values[name] = raw == "true"
        return cls(**values)

    def document(self):
        values = asdict(self)
        # Every group includes an immutable route; hardware is a group consumer.
        values["groups"] = self.groups and self.routes
        values["hardware"] = self.hardware and values["groups"]
        values["invitePreviews"] = self.invitePreviews and values["groups"] and self.media
        return values

    def require(self, name):
        if not self.document()[name]:
            raise SocialError("feature_unavailable", 503)

    def require_content(self, kind):
        self.require("routes" if kind == "route" else "activities")
