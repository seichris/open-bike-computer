"""Provider-scoped transport: validate the initial URL and every redirect."""
from __future__ import annotations

import urllib.parse
import urllib.request

GEOFABRIK_HOSTS = frozenset({"download.geofabrik.de", "download.openstreetmap.fr"})


def validate_geofabrik_url(value: str) -> str:
    try:
        url = urllib.parse.urlsplit(value)
        valid = (
            isinstance(value, str) and len(value) <= 2048 and url.scheme == "https"
            and url.hostname in GEOFABRIK_HOSTS and url.port in (None, 443)
            and not url.username and not url.password and not url.fragment
            and not url.query and not any(ord(char) <= 32 for char in value)
            and not any(part in (".", "..") for part in urllib.parse.unquote(url.path).split("/"))
        )
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise ValueError("source URL is outside the approved HTTPS provider")
    return value


class ProviderRedirectHandler(urllib.request.HTTPRedirectHandler):
    max_redirections = 3

    def redirect_request(self, request, response, code, message, headers, newurl):
        validate_geofabrik_url(newurl)
        return super().redirect_request(request, response, code, message, headers, newurl)


def open_geofabrik_url(request, *, timeout):
    validate_geofabrik_url(request.full_url if isinstance(request, urllib.request.Request) else request)
    return urllib.request.build_opener(ProviderRedirectHandler()).open(request, timeout=timeout)
