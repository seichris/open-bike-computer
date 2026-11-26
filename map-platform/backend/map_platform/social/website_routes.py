"""Signed bicino.com bridge for the account route library.

The website keeps only an HTTP-only Firebase session cookie, so it cannot
present the Firebase ID token the native API expects. Its server verifies the
session itself and then signs each route request for that account. The key is
derived from the existing website deletion secret with a distinct label, so a
deletion proof can never authorize a route request and no new secret has to be
provisioned.
"""
import hashlib
import heapq
import hmac
import json
import math

SIGNATURE_HEADER = "X-Bicino-Website-Signature"
KEY_LABEL = b"bicino-website-routes-v1"
PROOF_WINDOW_SECONDS = 60
PREVIEW_MAX_POINTS = 120
PREVIEW_STRIDE_POINTS = 1000
# The website imports GPX files only.
PREVIEW_PROVIDER = "user.imported-gpx"
STRAVA_PROVIDER = "strava.route"
# Geometry drawn on the website's OpenStreetMap thumbnails. Apple Maps routes
# never get a map preview.
PREVIEW_PROVIDERS = frozenset({PREVIEW_PROVIDER, STRAVA_PROVIDER})


def derive_key(secret: str) -> bytes:
    return hmac.new(secret.encode(), KEY_LABEL, hashlib.sha256).digest()


def signed_message(method: str, path: str, raw: bytes) -> bytes:
    return method.upper().encode() + b"\n" + path.encode() + b"\n" + raw


def valid_signature(key: bytes, method: str, path: str, raw: bytes, signature: str) -> bool:
    expected = hmac.new(key, signed_message(method, path, raw), hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature.encode(), expected.encode())


def _simplify(points, limit):
    """At most `limit` points that keep the route's shape, with bounded work.

    A stride first caps the input at PREVIEW_STRIDE_POINTS, then the farthest
    remaining point is added one at a time (Douglas-Peucker order, local
    equirectangular metres) until `limit` points are kept. Each split scans only
    its own span, so the cost is at most PREVIEW_STRIDE_POINTS * limit
    distance evaluations whatever the geometry.
    """
    if len(points) <= limit:
        return list(points)
    if len(points) > PREVIEW_STRIDE_POINTS:
        stride = math.ceil((len(points) - 1) / (PREVIEW_STRIDE_POINTS - 1))
        points = points[::stride] + ([points[-1]] if (len(points) - 1) % stride else [])
    latitude = math.radians(sum(p[0] for p in points) / len(points))
    scale = math.cos(latitude)
    xy = [(p[1] * scale, p[0]) for p in points]

    def farthest(start, end):
        (ax, ay), (bx, by) = xy[start], xy[end]
        dx, dy = bx - ax, by - ay
        length = dx * dx + dy * dy
        best, offset = None, 0.0
        for index in range(start + 1, end):
            px, py = xy[index]
            t = 0.0 if length == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length))
            distance = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if best is None or distance > offset:
                best, offset = index, distance
        return best, offset

    kept = {0, len(points) - 1}
    queue = []
    def push(start, end):
        index, offset = farthest(start, end)
        if index is not None:
            heapq.heappush(queue, (-offset, start, end, index))
    push(0, len(points) - 1)
    while queue and len(kept) < limit:
        _, start, end, index = heapq.heappop(queue)
        kept.add(index)
        push(start, index)
        push(index, end)
    return [points[index] for index in sorted(kept)]


def _encode_value(value: int) -> str:
    value = ~(value << 1) if value < 0 else value << 1
    chunks = []
    while value >= 0x20:
        chunks.append(chr((0x20 | (value & 0x1F)) + 63))
        value >>= 5
    chunks.append(chr(value + 63))
    return "".join(chunks)


def encode_polyline(points) -> str:
    """Google encoded polyline at 1e-5 precision, latitude first."""
    result, previous = [], (0, 0)
    for latitude, longitude in points:
        current = (round(latitude * 1e5), round(longitude * 1e5))
        result.append(_encode_value(current[0] - previous[0]))
        result.append(_encode_value(current[1] - previous[1]))
        previous = current
    return "".join(result)


def archive_identity(archive_text: str):
    """(provider ID, route ID) named by an archive, or (None, None) when unreadable."""
    try:
        route = json.loads(archive_text)["route"]
        provider, route_id = route["provider"]["providerID"], route["id"]
    except (KeyError, TypeError, ValueError, RecursionError):
        return None, None
    if not isinstance(provider, str) or not isinstance(route_id, str):
        return None, None
    return provider, route_id


def card_details(route):
    """Card fields for a validated route: provider, preview and, for Strava, its route URL."""
    provider = route["provider"]["providerID"]
    preview = None
    if provider in PREVIEW_PROVIDERS:
        preview = encode_polyline(_simplify([(p["latitude"], p["longitude"]) for p in route["points"]],
                                            PREVIEW_MAX_POINTS))
    details = {"provider": provider, "preview": preview}
    reference = route.get("sourceReference")
    if provider == STRAVA_PROVIDER and isinstance(reference, dict):
        details["sourceURL"] = reference.get("canonicalURL")
    return details


def summary(item):
    """The website's card fields from a summary row. Archives and owners stay private."""
    details = item.get("website") if isinstance(item.get("website"), dict) else {}
    distance = item.get("distanceMeters")
    def number(value):
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None
    preview = details.get("preview")
    provider = details.get("provider")
    return {
        "id": item["id"],
        "title": item["title"],
        "visibility": item["visibility"],
        "revision": item["revision"],
        "created": item["created"],
        # Routes stored before card fields existed list without a preview.
        "provider": provider if isinstance(provider, str) else None,
        "distanceMeters": number(distance),
        "elevationGainMeters": number(details.get("elevationGainMeters")),
        "durationSeconds": number(details.get("durationSeconds")),
        "favorite": details.get("favorite") is True,
        "preview": preview if isinstance(preview, str) and provider in PREVIEW_PROVIDERS else None,
        "sourceURL": source_url(provider, details.get("sourceURL")),
    }


def source_url(provider, value):
    """Only a canonical Strava route URL is ever handed to the website."""
    if provider != STRAVA_PROVIDER or not isinstance(value, str):
        return None
    prefix = "https://www.strava.com/routes/"
    route_id = value[len(prefix):] if value.startswith(prefix) else ""
    return value if route_id.isascii() and route_id.isdigit() and 1 <= len(route_id) <= 19 else None
