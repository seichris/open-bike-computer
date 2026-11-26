"""Owner-only forwarding to the production Strava integration."""

from __future__ import annotations

import hmac
import os
import re
from dataclasses import dataclass, field
from urllib.parse import urlencode

from .strava_client import (
    MAXIMUM_STRAVA_GPX_BYTES,
    StravaClientError,
    StravaHTTPResponse,
    UrllibStravaTransport,
)
from .strava_integrations import (
    STRAVA_INSTALLATION_ID_PATTERN,
    StravaIntegrationError,
)

DEVELOPMENT_HEADER = "X-Bicino-Strava-Development"
PRODUCTION_ORIGIN = "https://maps.8o.vc"
ROUTE_PREFIX = "/v1/integrations/strava"
_FORWARDED_PATH = re.compile(
    ROUTE_PREFIX + r"/(?:oauth/start|connection|routes(?:/[1-9][0-9]{0,18}/(?:gpx|validate))?)"
)


@dataclass(frozen=True)
class StravaDevelopmentBridge:
    channel: str
    installation_id: str
    secret: str = field(repr=False)
    athlete_id: str | None = None

    @classmethod
    def from_environment(cls, channel: str) -> StravaDevelopmentBridge | None:
        secret = os.environ.get("MAP_PLATFORM_STRAVA_DEVELOPMENT_BRIDGE_SECRET", "")
        installation = os.environ.get("MAP_PLATFORM_STRAVA_DEVELOPMENT_INSTALLATION", "")
        athlete = os.environ.get("MAP_PLATFORM_STRAVA_DEVELOPMENT_ATHLETE", "")
        if not (secret or installation or athlete):
            return None
        if (
            re.fullmatch(r"[A-Za-z0-9_-]{43,128}", secret) is None
            or STRAVA_INSTALLATION_ID_PATTERN.fullmatch(installation) is None
            or (channel == "development" and athlete)
            or (channel == "production" and re.fullmatch(r"[1-9][0-9]{0,18}", athlete) is None)
        ):
            raise ValueError("Strava development bridge configuration is invalid")
        return cls(channel, installation, secret, athlete or None)

    def permits_installation(self, installation_id: str) -> bool:
        return installation_id == self.installation_id

    def authorizes_forward(self, installation_id: str, presented: list[str]) -> bool:
        return (
            self.channel == "production"
            and self.permits_installation(installation_id)
            and len(presented) == 1
            and presented[0].isascii()
            and hmac.compare_digest(presented[0], self.secret)
        )

    def forward(
        self, method: str, path: str, *, page: int | None = None
    ) -> StravaHTTPResponse:
        if self.channel != "development" or _FORWARDED_PATH.fullmatch(path) is None:
            raise StravaIntegrationError("strava_route_unavailable", status_code=404)
        query: dict[str, str | int] = {"clientInstallationId": self.installation_id}
        if page is not None:
            query["page"] = page
        url = f"{PRODUCTION_ORIGIN}{path}?{urlencode(query)}"
        try:
            response = UrllibStravaTransport().request(
                method=method,
                url=url,
                headers={DEVELOPMENT_HEADER: self.secret},
                body=None,
                timeout_seconds=30,
                maximum_body_bytes=MAXIMUM_STRAVA_GPX_BYTES,
            )
        except StravaClientError as exc:
            raise StravaIntegrationError(
                "strava_temporarily_unavailable", status_code=503
            ) from exc
        if (
            response.final_url != url
            or response.status_code not in {200, 400, 401, 403, 404, 409, 422, 429, 502, 503}
            or len(response.body) > MAXIMUM_STRAVA_GPX_BYTES
        ):
            raise StravaIntegrationError("strava_temporarily_unavailable", status_code=503)
        return response
