"""Signed bicino.com bridge for the account route library.

The website keeps only an HTTP-only Firebase session cookie, so it cannot
present the Firebase ID token the native API expects. Its server verifies the
session itself and then signs each route request for that account. The key is
derived from the existing website deletion secret with a distinct label, so a
deletion proof can never authorize a route request and no new secret has to be
provisioned.
"""
import hashlib
import hmac
import json
import math

SIGNATURE_HEADER = "X-Bicino-Website-Signature"
KEY_LABEL = b"bicino-website-routes-v1"
PROOF_WINDOW_SECONDS = 60
PREVIEW_MAX_POINTS = 120
# Only this provider's geometry is drawn on the website's OpenStreetMap
# thumbnails. Saved Apple Maps routes stay listed without a map preview.
PREVIEW_PROVIDER = "user.imported-gpx"


def derive_key(secret: str) -> bytes:
    return hmac.new(secret.encode(), KEY_LABEL, hashlib.sha256).digest()


def signed_message(method: str, path: str, raw: bytes) -> bytes:
    return method.upper().encode() + b"\n" + path.encode() + b"\n" + raw


def valid_signature(key: bytes, method: str, path: str, raw: bytes, signature: str) -> bool:
    expected = hmac.new(key, signed_message(method, path, raw), hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature.encode(), expected.encode())


def _simplify(points, limit):
    """Douglas-Peucker on a local equirectangular projection, capped at `limit`."""
    if len(points) <= limit:
        return points
    latitude = math.radians(sum(p[0] for p in points) / len(points))
    scale = math.cos(latitude)
    xy = [(p[1] * scale, p[0]) for p in points]

    def keep(tolerance):
        kept = [False] * len(points)
        kept[0] = kept[-1] = True
        stack = [(0, len(points) - 1)]
        while stack:
            start, end = stack.pop()
            (ax, ay), (bx, by) = xy[start], xy[end]
            dx, dy = bx - ax, by - ay
            length = dx * dx + dy * dy
            farthest, distance = None, tolerance
            for index in range(start + 1, end):
                px, py = xy[index]
                if length == 0:
                    offset = math.hypot(px - ax, py - ay)
                else:
                    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length))
                    offset = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
                if offset > distance:
                    farthest, distance = index, offset
            if farthest is not None:
                kept[farthest] = True
                stack.append((start, farthest))
                stack.append((farthest, end))
        return [point for point, flag in zip(points, kept) if flag]

    span = max(max(x for x, _ in xy) - min(x for x, _ in xy), max(y for _, y in xy) - min(y for _, y in xy))
    tolerance = max(span / 500, 1e-7)
    result = keep(tolerance)
    while len(result) > limit:
        tolerance *= 1.5
        result = keep(tolerance)
    return result


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


def preview_for_archive(archive_text: str):
    """(provider ID, polyline or None) for a stored, already validated archive."""
    try:
        route = json.loads(archive_text)["route"]
        provider = route["provider"]["providerID"]
        if provider != PREVIEW_PROVIDER:
            return provider, None
        points = [(p["latitude"], p["longitude"]) for p in route["points"]]
    except (KeyError, TypeError, ValueError):
        return None, None
    return provider, encode_polyline(_simplify(points, PREVIEW_MAX_POINTS))


def summary(item):
    """The website's card fields. Archives, hash payloads and owners stay private."""
    body = item["body"] if isinstance(item.get("body"), dict) else {}
    details = body.get("website") if isinstance(body.get("website"), dict) else {}
    provider, preview = details.get("provider"), details.get("preview")
    if provider is None and isinstance(body.get("archive"), str):
        provider, preview = preview_for_archive(body["archive"])
    distance = body.get("distanceMeters")
    return {
        "id": item["id"],
        "title": item["title"],
        "visibility": item["visibility"],
        "revision": item["revision"],
        "created": item["created"],
        "provider": provider,
        "distanceMeters": distance if isinstance(distance, (int, float)) else None,
        "elevationGainMeters": details.get("elevationGainMeters"),
        "durationSeconds": details.get("durationSeconds"),
        "favorite": details.get("favorite") is True,
        "preview": preview,
    }
