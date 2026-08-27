from __future__ import annotations

import json
import re
import socket
from dataclasses import dataclass
from typing import Mapping, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .strict_json import loads_strict_json


STRAVA_HTTPS_ORIGIN = "https://www.strava.com"
STRAVA_API_BASE = f"{STRAVA_HTTPS_ORIGIN}/api/v3"
STRAVA_OAUTH_TOKEN_URL = f"{STRAVA_HTTPS_ORIGIN}/oauth/token"
STRAVA_OAUTH_REVOKE_URL = f"{STRAVA_HTTPS_ORIGIN}/oauth/deauthorize"
STRAVA_WEB_AUTHORIZE_URL = f"{STRAVA_HTTPS_ORIGIN}/oauth/mobile/authorize"
STRAVA_NATIVE_AUTHORIZE_URL = "strava://oauth/mobile/authorize"
MAXIMUM_STRAVA_JSON_BYTES = 512 * 1_024
MAXIMUM_STRAVA_GPX_BYTES = 4 * 1_024 * 1_024
MAXIMUM_SIGNED_64_BIT_ID = 9_223_372_036_854_775_807
STRAVA_ROUTE_ID_PATTERN = re.compile(r"[1-9][0-9]{0,18}")


class StravaClientError(RuntimeError):
    def __init__(
        self,
        code: str,
        *,
        status_code: int,
        retry_after_seconds: int | None = None,
    ):
        super().__init__(code)
        self.code = code
        self.status_code = status_code
        self.retry_after_seconds = retry_after_seconds


@dataclass(frozen=True)
class StravaHTTPResponse:
    status_code: int
    headers: Mapping[str, str]
    body: bytes
    final_url: str


class StravaTransport(Protocol):
    def request(
        self,
        *,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: bytes | None,
        timeout_seconds: float,
        maximum_body_bytes: int,
    ) -> StravaHTTPResponse: ...


class _NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class UrllibStravaTransport:
    """Small fixed-host transport that never follows an upstream redirect."""

    def __init__(self):
        self._opener = build_opener(_NoRedirectHandler())

    def request(
        self,
        *,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: bytes | None,
        timeout_seconds: float,
        maximum_body_bytes: int,
    ) -> StravaHTTPResponse:
        request = Request(
            url,
            data=body,
            method=method,
            headers=dict(headers),
        )
        try:
            response = self._opener.open(request, timeout=timeout_seconds)
            try:
                payload = response.read(maximum_body_bytes + 1)
                return StravaHTTPResponse(
                    status_code=int(response.status),
                    headers={key.lower(): value for key, value in response.headers.items()},
                    body=payload,
                    final_url=response.geturl(),
                )
            finally:
                response.close()
        except HTTPError as exc:
            try:
                payload = exc.read(maximum_body_bytes + 1)
            finally:
                exc.close()
            return StravaHTTPResponse(
                status_code=int(exc.code),
                headers={key.lower(): value for key, value in exc.headers.items()},
                body=payload,
                final_url=exc.geturl(),
            )
        except (URLError, socket.timeout, TimeoutError, OSError) as exc:
            raise StravaClientError(
                "strava_temporarily_unavailable",
                status_code=503,
            ) from exc


@dataclass(frozen=True)
class StravaTokenResponse:
    access_token: str
    refresh_token: str
    expires_at: int
    athlete_id: str | None


@dataclass(frozen=True)
class StravaRouteMetadata:
    route_id: str
    athlete_id: str
    route_type: int


@dataclass(frozen=True)
class StravaAuthorizationURLs:
    app_url: str
    web_url: str


class StravaClient:
    def __init__(
        self,
        *,
        client_id: str,
        client_secret: str,
        redirect_uri: str,
        transport: StravaTransport | None = None,
        timeout_seconds: float = 12.0,
    ):
        if not client_id.isascii() or not client_id.isdigit() or int(client_id) <= 0:
            raise ValueError("Strava client ID is invalid")
        if not client_secret:
            raise ValueError("Strava client secret is missing")
        if not redirect_uri.startswith("https://"):
            raise ValueError("Strava redirect URI must use HTTPS")
        if not 1 <= timeout_seconds <= 60:
            raise ValueError("Strava request timeout is invalid")
        self.client_id = client_id
        self._client_secret = client_secret
        self.redirect_uri = redirect_uri
        self._transport = transport or UrllibStravaTransport()
        self._timeout_seconds = timeout_seconds

    def authorization_urls(self, state: str) -> StravaAuthorizationURLs:
        if re.fullmatch(r"[A-Za-z0-9_-]{32,256}", state) is None:
            raise ValueError("Strava OAuth state is invalid")
        query = urlencode(
            {
                "client_id": self.client_id,
                "redirect_uri": self.redirect_uri,
                "response_type": "code",
                "approval_prompt": "auto",
                "scope": "read,read_all",
                "state": state,
            }
        )
        return StravaAuthorizationURLs(
            app_url=f"{STRAVA_NATIVE_AUTHORIZE_URL}?{query}",
            web_url=f"{STRAVA_WEB_AUTHORIZE_URL}?{query}",
        )

    def exchange_code(self, code: str) -> StravaTokenResponse:
        if re.fullmatch(r"[A-Za-z0-9_-]{1,512}", code) is None:
            raise StravaClientError("strava_invalid_response", status_code=502)
        return self._token_request(
            {
                "client_id": self.client_id,
                "client_secret": self._client_secret,
                "code": code,
                "grant_type": "authorization_code",
            },
            require_athlete=True,
        )

    def refresh_token(self, refresh_token: str) -> StravaTokenResponse:
        self._validate_token_text(refresh_token)
        return self._token_request(
            {
                "client_id": self.client_id,
                "client_secret": self._client_secret,
                "refresh_token": refresh_token,
                "grant_type": "refresh_token",
            },
            require_athlete=False,
        )

    def revoke(self, access_token: str) -> None:
        self._validate_token_text(access_token)
        response = self._request(
            method="POST",
            url=STRAVA_OAUTH_REVOKE_URL,
            headers={"Authorization": f"Bearer {access_token}"},
            body=b"",
            maximum_body_bytes=MAXIMUM_STRAVA_JSON_BYTES,
        )
        if response.status_code in {200, 204, 401}:
            return
        self._raise_for_status(response, unavailable_is_not_found=False)

    def route_metadata(
        self,
        route_id: str,
        access_token: str,
    ) -> StravaRouteMetadata:
        route_id = validate_strava_route_id(route_id)
        self._validate_token_text(access_token)
        response = self._request(
            method="GET",
            url=f"{STRAVA_API_BASE}/routes/{route_id}",
            headers={"Authorization": f"Bearer {access_token}"},
            body=None,
            maximum_body_bytes=MAXIMUM_STRAVA_JSON_BYTES,
        )
        self._raise_for_status(response, unavailable_is_not_found=True)
        self._require_content_type(response, {"application/json"})
        document = self._json_document(response.body, "Strava route response")
        if not isinstance(document, dict):
            raise StravaClientError("strava_invalid_response", status_code=502)
        response_route_id = _strict_id(document.get("id"))
        athlete = document.get("athlete")
        athlete_id = _strict_id(athlete.get("id")) if isinstance(athlete, dict) else None
        route_type = document.get("type")
        if (
            response_route_id != route_id
            or athlete_id is None
            or isinstance(route_type, bool)
            or not isinstance(route_type, int)
        ):
            raise StravaClientError("strava_invalid_response", status_code=502)
        return StravaRouteMetadata(
            route_id=response_route_id,
            athlete_id=athlete_id,
            route_type=route_type,
        )

    def export_gpx(self, route_id: str, access_token: str) -> bytes:
        route_id = validate_strava_route_id(route_id)
        self._validate_token_text(access_token)
        response = self._request(
            method="GET",
            url=f"{STRAVA_API_BASE}/routes/{route_id}/export_gpx",
            headers={"Authorization": f"Bearer {access_token}"},
            body=None,
            maximum_body_bytes=MAXIMUM_STRAVA_GPX_BYTES,
        )
        self._raise_for_status(response, unavailable_is_not_found=True)
        content_type = response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
        if content_type not in {
            "application/gpx+xml",
            "application/xml",
            "text/xml",
        }:
            raise StravaClientError("strava_invalid_response", status_code=502)
        if not response.body:
            raise StravaClientError("strava_invalid_response", status_code=502)
        return response.body

    def _token_request(
        self,
        parameters: Mapping[str, str],
        *,
        require_athlete: bool,
    ) -> StravaTokenResponse:
        response = self._request(
            method="POST",
            url=STRAVA_OAUTH_TOKEN_URL,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            body=urlencode(parameters).encode("ascii"),
            maximum_body_bytes=MAXIMUM_STRAVA_JSON_BYTES,
        )
        self._raise_for_status(response, unavailable_is_not_found=False)
        self._require_content_type(response, {"application/json"})
        document = self._json_document(response.body, "Strava token response")
        if not isinstance(document, dict):
            raise StravaClientError("strava_invalid_response", status_code=502)
        access_token = document.get("access_token")
        refresh_token = document.get("refresh_token")
        expires_at = document.get("expires_at")
        token_type = document.get("token_type")
        athlete = document.get("athlete")
        athlete_id = _strict_id(athlete.get("id")) if isinstance(athlete, dict) else None
        if (
            not isinstance(access_token, str)
            or not isinstance(refresh_token, str)
            or isinstance(expires_at, bool)
            or not isinstance(expires_at, int)
            or expires_at <= 0
            or not isinstance(token_type, str)
            or token_type.lower() != "bearer"
            or (require_athlete and athlete_id is None)
        ):
            raise StravaClientError("strava_invalid_response", status_code=502)
        self._validate_token_text(access_token)
        self._validate_token_text(refresh_token)
        return StravaTokenResponse(
            access_token=access_token,
            refresh_token=refresh_token,
            expires_at=expires_at,
            athlete_id=athlete_id,
        )

    def _request(
        self,
        *,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: bytes | None,
        maximum_body_bytes: int,
    ) -> StravaHTTPResponse:
        response = self._transport.request(
            method=method,
            url=url,
            headers={
                "Accept": "application/json, application/gpx+xml, application/xml",
                "User-Agent": "Bicino-Strava-Integration/1",
                **headers,
            },
            body=body,
            timeout_seconds=self._timeout_seconds,
            maximum_body_bytes=maximum_body_bytes,
        )
        if response.final_url != url:
            raise StravaClientError("strava_invalid_response", status_code=502)
        if len(response.body) > maximum_body_bytes:
            code = (
                "strava_route_too_large"
                if maximum_body_bytes == MAXIMUM_STRAVA_GPX_BYTES
                else "strava_invalid_response"
            )
            raise StravaClientError(
                code,
                status_code=413 if code == "strava_route_too_large" else 502,
            )
        return response

    @staticmethod
    def _raise_for_status(
        response: StravaHTTPResponse,
        *,
        unavailable_is_not_found: bool,
    ) -> None:
        if 200 <= response.status_code < 300:
            return
        if response.status_code == 401:
            raise StravaClientError("strava_token_rejected", status_code=401)
        if response.status_code in {403, 404} and unavailable_is_not_found:
            raise StravaClientError("strava_route_unavailable", status_code=404)
        if response.status_code == 429:
            retry_after = _bounded_retry_after(response.headers.get("retry-after"))
            raise StravaClientError(
                "strava_rate_limited",
                status_code=429,
                retry_after_seconds=retry_after,
            )
        if response.status_code >= 500:
            raise StravaClientError(
                "strava_temporarily_unavailable",
                status_code=503,
            )
        raise StravaClientError("strava_invalid_response", status_code=502)

    @staticmethod
    def _json_document(body: bytes, description: str) -> object:
        try:
            return loads_strict_json(body, description=description)
        except ValueError as exc:
            raise StravaClientError("strava_invalid_response", status_code=502) from exc

    @staticmethod
    def _require_content_type(
        response: StravaHTTPResponse,
        allowed: set[str],
    ) -> None:
        content_type = (
            response.headers.get("content-type", "")
            .split(";", 1)[0]
            .strip()
            .lower()
        )
        if content_type not in allowed:
            raise StravaClientError("strava_invalid_response", status_code=502)

    @staticmethod
    def _validate_token_text(value: str) -> None:
        if (
            not isinstance(value, str)
            or not 1 <= len(value) <= 4_096
            or any(ord(character) < 0x21 or ord(character) > 0x7E for character in value)
        ):
            raise StravaClientError("strava_invalid_response", status_code=502)


def validate_strava_route_id(value: str) -> str:
    if not isinstance(value, str) or STRAVA_ROUTE_ID_PATTERN.fullmatch(value) is None:
        raise StravaClientError("invalid_strava_route_id", status_code=400)
    if int(value) > MAXIMUM_SIGNED_64_BIT_ID:
        raise StravaClientError("invalid_strava_route_id", status_code=400)
    return value


def _strict_id(value: object) -> str | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        candidate = str(value)
    elif isinstance(value, str):
        candidate = value
    else:
        return None
    try:
        return validate_strava_route_id(candidate)
    except StravaClientError:
        return None


def _bounded_retry_after(value: str | None) -> int | None:
    if value is None or re.fullmatch(r"[0-9]{1,7}", value.strip()) is None:
        return None
    return min(max(int(value), 1), 86_400)
