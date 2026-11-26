"""Strict validation of imported GPX and explicitly saved Apple Maps archives."""
import hashlib
import json
import math
import struct
import uuid
from .models import Point

FINGERPRINT_DOMAIN = b"bicino-route-geometry-v1"

# Exact metadata, not a self-declared durable scope. Ordinary active-only MapKit
# responses, Strava and relabelled provider combinations remain ineligible.
# Maintainer-requested product policy, not an attestation of Apple permission.
SOCIAL_PROVIDERS = (
    {'providerID': 'user.imported-gpx', 'attribution': 'User-provided GPX', 'storageScope': 'durable'},
    {'providerID': 'apple.mapkit', 'attribution': 'Apple Maps', 'storageScope': 'phoneOnly'},
)
STRAVA_PROVIDER = {'providerID': 'strava.route', 'attribution': 'Strava', 'storageScope': 'durable'}
# An account's private route library (synced between the app and bicino.com)
# holds imported GPX and Strava API routes. Maintainer decision 2026-11-26:
# Strava routes sync and are kept without the app's seven-day expiry. Library
# rows are never shared, so Strava data stays with the account that imported it.
LIBRARY_PROVIDERS = (SOCIAL_PROVIDERS[0], STRAVA_PROVIDER)


def _strava_reference(reference):
    """The app's `RouteSourceReferenceV1` for a Strava route URL."""
    if not isinstance(reference, dict) or set(reference) != {'providerID', 'externalRouteID', 'canonicalURL'}:
        return False
    route_id = reference['externalRouteID']
    return (reference['providerID'] == STRAVA_PROVIDER['providerID'] and isinstance(route_id, str)
            and 1 <= len(route_id) <= 19 and route_id.isascii() and route_id.isdigit() and route_id[0] != '0'
            and int(route_id) <= 2**63 - 1
            and reference['canonicalURL'] == f'https://www.strava.com/routes/{route_id}')


def _scaled(value):
    value *= 1_000_000
    return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)


def route_fingerprint(points):
    """Identify route geometry independently of route ID, revision, title or direction.

    Coordinates use the same E6 rounding as archive validation. The native app
    computes the identical value, so ID-changed duplicates and reversed copies of
    a received route still match.
    """
    scaled = [(_scaled(p["latitude"]), _scaled(p["longitude"])) for p in points]
    def digest(sequence):
        value = hashlib.sha256(FINGERPRINT_DOMAIN)
        for latitude, longitude in sequence:
            value.update(struct.pack("<ii", latitude, longitude))
        return value.hexdigest()
    return min(digest(scaled), digest(reversed(scaled)))


def archive_fingerprint(body):
    """Fingerprint a stored route body or ride snapshot; None when it holds no route."""
    try:
        archive = json.loads(body["archive"])
        return route_fingerprint(archive["route"]["points"])
    except (KeyError, TypeError, ValueError, struct.error):
        return None


def validate_archive(archive, library=False):
    """Validate a stored route archive.

    Shared routes accept imported GPX and saved Apple Maps archives without a
    source reference or deadline. A private library row (`library=True`) also
    accepts the app's Strava archive with its Strava URL and seven-day
    `deleteAfter`; the server keeps the row regardless of that deadline.
    """
    if set(archive)-{'schemaVersion','route','createdAt','contentHash','deleteAfter'}:
        raise ValueError('archive_fields')
    if type(archive['schemaVersion']) is not int or archive['schemaVersion'] != 1:
        raise ValueError('archive_version')
    if not math.isfinite(archive['createdAt']) or archive['createdAt'] < 0:
        raise ValueError('archive_date')
    route=archive['route']
    allowed={'id','revision','provider','sourceReference','localeIdentifier','transportType','source','destination','bounds','distanceMeters','expectedTravelTimeSeconds','name','points','steps','normalizationVersion'}
    if set(route)-allowed or not uuid.UUID(route['id']).int:
        raise ValueError('route_fields')
    strava = library and route.get('provider') == STRAVA_PROVIDER
    if strava:
        delete_after = archive.get('deleteAfter')
        if (type(delete_after) not in {int, float} or not math.isfinite(delete_after)
                or delete_after <= archive['createdAt'] or not _strava_reference(route.get('sourceReference'))):
            raise ValueError('route_identity')
    elif archive.get('deleteAfter') is not None or route.get('sourceReference') is not None:
        raise ValueError('archive_version')
    if (route['provider'] not in (LIBRARY_PROVIDERS if library else SOCIAL_PROVIDERS)
            or route['transportType'] != 'cycling'
            or not type(route['revision']) is int or not 1 <= route['revision'] <= 2**32-1
            or not type(route['normalizationVersion']) is int or not 1 <= route['normalizationVersion'] <= 65535
            or not isinstance(route['localeIdentifier'],str) or not 1 <= len(route['localeIdentifier']) <= 128):
        raise ValueError('route_identity')
    if not math.isfinite(route['distanceMeters']) or not 0 < route['distanceMeters'] <= 5_000_000:
        raise ValueError('route_distance')
    duration=route.get('expectedTravelTimeSeconds')
    if duration is not None and (not math.isfinite(duration) or duration <= 0):
        raise ValueError('route_duration')
    if route.get('name') is not None and (not isinstance(route['name'],str) or len(route['name'])>160):
        raise ValueError('route_name')
    points=route['points']
    if not 2 <= len(points) <= 20000 or all(p==points[0] for p in points):
        raise ValueError('route_geometry')
    for p in points:
        Point.model_validate(p)
        if any(type(v) not in {int,float} for v in p.values()): raise ValueError('coordinate_type')
    def scaled(value):
        value *= 1_000_000
        return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)
    for a,b in zip(points, points[1:]):
        if any(not -32768 <= scaled(b[key])-scaled(a[key]) <= 32767 for key in ('latitude','longitude')):
            raise ValueError('route_delta')
    for endpoint,point in [(route['source'],points[0]),(route['destination'],points[-1])]:
        if set(endpoint) != {'coordinate','label'} or endpoint['coordinate'] != point or not endpoint['label'].strip() or len(endpoint['label'].encode())>1024:
            raise ValueError('route_endpoint')
    bounds=route['bounds']
    if set(bounds) != {'south','west','north','east'} or not all(math.isfinite(v) for v in bounds.values()):
        raise ValueError('route_bounds')
    if not (-90<=bounds['south']<=min(p['latitude'] for p in points) and max(p['latitude'] for p in points)<=bounds['north']<=90
        and -180<=bounds['west']<=min(p['longitude'] for p in points) and max(p['longitude'] for p in points)<=bounds['east']<=180):
        raise ValueError('route_bounds')
    steps=route['steps']
    if not 1<=len(steps)<=2000: raise ValueError('route_steps')
    previous=0;ids=set()
    for step in steps:
        if set(step) != {'id','geometryStartIndex','geometryEndIndex','instruction','maneuver','distanceMeters'}:
            raise ValueError('route_step_fields')
        if (step['id'] in ids or not type(step['id']) is int or not 0<=step['id']<=2**32-1
                or step['geometryStartIndex'] != previous or not type(step['geometryEndIndex']) is int
                or not previous<=step['geometryEndIndex']<len(points)
                or not step['instruction'].strip() or len(step['instruction'].encode())>1024
                or step['maneuver'] not in {'straight','slightLeft','left','sharpLeft','slightRight','right','sharpRight','uTurn','roundabout','arrive','unknown'}
                or not math.isfinite(step['distanceMeters']) or step['distanceMeters']<0):
            raise ValueError('route_step')
        ids.add(step['id']);previous=step['geometryEndIndex']
    if previous != len(points)-1: raise ValueError('route_steps')
