"""WGS-84 social geometry. No hidden track points are returned in derivatives."""
from __future__ import annotations

import math

EARTH = 6371008.8


def distance(a, b):
    p, q = math.radians(a["latitude"]), math.radians(b["latitude"])
    dp = q-p
    dl = math.radians(b["longitude"]-a["longitude"])
    h = math.sin(dp/2)**2 + math.cos(p)*math.cos(q)*math.sin(dl/2)**2
    return 2 * EARTH * math.asin(math.sqrt(min(1, max(0, h))))


def interpolate(a, b, fraction):
    # Spherical interpolation handles the antimeridian without a world-spanning line.
    def vector(p):
        lat, lon = math.radians(p["latitude"]), math.radians(p["longitude"])
        return math.cos(lat)*math.cos(lon), math.cos(lat)*math.sin(lon), math.sin(lat)
    x, y = vector(a), vector(b)
    angle = math.acos(max(-1, min(1, sum(u*v for u, v in zip(x, y)))))
    if angle < 1e-10:
        return dict(a)
    if angle > math.pi-1e-5:
        raise ValueError("ambiguous_track_segment")
    l, r = math.sin((1-fraction)*angle)/math.sin(angle), math.sin(fraction*angle)/math.sin(angle)
    v = [l*u+r*w for u, w in zip(x, y)]
    return {"latitude": math.degrees(math.atan2(v[2], math.hypot(v[0], v[1]))),
            "longitude": math.degrees(math.atan2(v[1], v[0]))}


def sanitize_track(points, zones):
    if not 2 <= len(points) <= 20000:
        raise ValueError("track_size")
    zones = list(zones) + [dict(points[0], radius=200), dict(points[-1], radius=200)]
    segments, current = [], []
    total_samples = 0
    for a, b in zip(points, points[1:]):
        count = max(1, math.ceil(distance(a, b)/25))
        total_samples += count
        if total_samples > 100000:
            raise ValueError("track_too_long")
        for i in range(count):
            p = interpolate(a, b, i/count)
            # A 25 m conservative halo makes every retained segment safe even
            # when it passes between adjacent samples near a privacy boundary.
            hidden = any(distance(p, zone) <= zone["radius"]+25 for zone in zones)
            if hidden:
                if len(current) > 1:
                    segments.append(current)
                current = []
            else:
                current.append(p)
    # Final point is intentionally hidden by its endpoint privacy zone.
    if len(current) > 1:
        segments.append(current)
    meters = sum(distance(a, b) for segment in segments for a, b in zip(segment, segment[1:]))
    return {"segments": segments, "distanceMeters": meters, "privacyVersion": 1}


def route_progress(points, point, previous=None, elapsed=None):
    """Return a confident along-route position; ambiguity is explicitly unknown."""
    walked, candidates = 0.0, []
    for a, b in zip(points, points[1:]):
        length = distance(a, b)
        if length < 0.01:
            continue
        if min(distance(a, point), distance(b, point)) > length + 50:
            walked += length
            continue
        # Bounded nearest-point search on the spherical segment.
        lo, hi = 0.0, 1.0
        for _ in range(14):
            x, y = lo+(hi-lo)/3, hi-(hi-lo)/3
            if distance(interpolate(a, b, x), point) < distance(interpolate(a, b, y), point):
                hi = y
            else:
                lo = x
        fraction = (lo+hi)/2
        gap = distance(interpolate(a, b, fraction), point)
        if gap < 50:
            course = point.get("course")
            if course is not None:
                p, q = math.radians(a["latitude"]), math.radians(b["latitude"])
                dl = math.radians(b["longitude"]-a["longitude"])
                bearing = math.degrees(math.atan2(math.sin(dl)*math.cos(q), math.cos(p)*math.sin(q)-math.sin(p)*math.cos(q)*math.cos(dl)))
                if abs((course-bearing+180) % 360-180) > 90:
                    walked += length
                    continue
            progress = walked+fraction*length
            if previous is None or elapsed is None or abs(progress-previous) <= 60*elapsed+100:
                candidates.append((gap, progress))
        walked += length
    candidates.sort()
    if not candidates:
        return None
    best = candidates[0]
    if any(gap < best[0]+10 and abs(progress-best[1]) > 100 for gap, progress in candidates[1:]):
        return None
    return best[1]
