import hashlib
import hmac
import json
import os
import unittest
import uuid
from unittest.mock import patch

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from map_platform.social import website_routes
from map_platform.social.api import create_app
from map_platform.social.database import Database, accounts, content
from map_platform.social.features import SocialFeatures
from map_platform.social.media import MemoryMedia
from map_platform.social.service import SocialService
from map_platform.user_auth import AccountPrincipal

SECRET = 'w' * 40
GPX = {'providerID': 'user.imported-gpx', 'attribution': 'User-provided GPX', 'storageScope': 'durable'}
APPLE = {'providerID': 'apple.mapkit', 'attribution': 'Apple Maps', 'storageScope': 'phoneOnly'}


class Identity:
    project = 'test'

    def verify(self, token):
        if token not in {'alice', 'bob'}:
            raise ValueError()
        return AccountPrincipal('test', token, 1000000)


STRAVA = {'providerID': 'strava.route', 'attribution': 'Strava', 'storageScope': 'durable'}
STRAVA_REFERENCE = {'providerID': 'strava.route', 'externalRouteID': '3405986242',
                    'canonicalURL': 'https://www.strava.com/routes/3405986242'}


def archive_body(points, provider=GPX, route_id=None, revision=1, name='Loop'):
    coordinates = [{'latitude': lat, 'longitude': lon} for lat, lon in points]
    archive = {'schemaVersion': 1, 'createdAt': 1000000000, 'route': {
        'id': route_id or str(uuid.uuid4()).upper(), 'revision': revision, 'provider': provider,
        'localeIdentifier': 'en_US', 'transportType': 'cycling', 'normalizationVersion': 1,
        'source': {'coordinate': coordinates[0], 'label': 'GPX start'},
        'destination': {'coordinate': coordinates[-1], 'label': 'GPX destination'},
        'bounds': {'south': min(p[0] for p in points), 'west': min(p[1] for p in points),
                   'north': max(p[0] for p in points), 'east': max(p[1] for p in points)},
        'distanceMeters': 2000, 'name': name, 'points': coordinates,
        'steps': [{'id': 1, 'geometryStartIndex': 0, 'geometryEndIndex': len(points) - 1,
                   'instruction': 'Arrive at GPX destination', 'maneuver': 'arrive', 'distanceMeters': 2000}]}}
    if provider == STRAVA:
        archive['route']['sourceReference'] = STRAVA_REFERENCE
        archive['deleteAfter'] = archive['createdAt'] + 604_800_000
    payload = json.dumps(archive, separators=(',', ':'), sort_keys=True)
    archive['contentHash'] = hashlib.sha256(payload.encode()).hexdigest()
    return {'archive': json.dumps(archive), 'hashPayload': payload}


LINE = [(1.30, 103.85), (1.301, 103.851), (1.302, 103.853), (1.304, 103.854)]


class RouteStoreCase(unittest.TestCase):
    """Shared social service, signed-website and native helpers."""

    def setUp(self):
        self.clock = 1000000.
        url = os.environ.get('BICINO_SOCIAL_TEST_DATABASE_URL', 'sqlite://')
        if url != 'sqlite://':
            if not url.endswith('/social_test') or '@127.0.0.1:' not in url:
                raise ValueError('isolated social_test database required')
        self.db = Database(url, testing=True)
        if url != 'sqlite://':
            from map_platform.social.database import metadata
            metadata.drop_all(self.db.engine)
        self.db.migrate()
        self.service = SocialService(self.db, MemoryMedia(), lambda: self.clock)
        self.client = TestClient(create_app(service=self.service, identity=Identity(),
                                            features=SocialFeatures(True, True, True, True, True)))
        self.environment = patch.dict(os.environ, {'BICINO_SOCIAL_DELETION_SECRET': SECRET,
                                                   'BICINO_FIREBASE_PROJECT_ID': 'test'})
        self.environment.start()
        self.counter = 0

    def tearDown(self):
        self.environment.stop()
        self.client.close()
        self.db.engine.dispose()

    def native(self, who, method, path, body=None):
        self.counter += 1
        return self.client.request(method, path, json=body, headers={
            'Authorization': 'Bearer ' + who, 'Idempotency-Key': f'native-{self.counter}'})

    def website(self, method, path, body=None, uid='alice', secret=SECRET, issued=None, nonce=None,
                signed_path=None, key=None, project='test', idempotency=True):
        nonce = nonce or str(uuid.uuid4())
        body = dict(body or {}, account={'uid': uid, 'project': project, 'nonce': nonce,
                                         'issuedAt': int(self.clock if issued is None else issued)})
        raw = json.dumps(body).encode()
        signing_key = key if key is not None else website_routes.derive_key(secret)
        signature = hmac.new(signing_key, website_routes.signed_message(method, signed_path or path, raw),
                             'sha256').hexdigest()
        headers = {'Content-Type': 'application/json', website_routes.SIGNATURE_HEADER: signature}
        if idempotency:
            headers['Idempotency-Key'] = nonce
        return self.client.request(method, path, content=raw, headers=headers)

    def imported(self, uid='alice', points=LINE, **extra):
        body = dict(archive_body(points), title='Sa Calobra loop', **extra)
        response = self.website('POST', '/internal/website/routes', body, uid=uid)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def listed(self, uid='alice'):
        response = self.website('POST', '/internal/website/routes/list', uid=uid)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()['items']

    def account_count(self):
        with self.db.transaction() as c:
            return c.scalar(select(func.count()).select_from(accounts))


class WebsiteRoutesTest(RouteStoreCase):
    def test_requests_are_verified_before_any_account_work(self):
        path = '/internal/website/routes/list'
        unsigned = self.client.post(path, json={'account': {'uid': 'alice', 'project': 'test',
                                                            'issuedAt': int(self.clock), 'nonce': str(uuid.uuid4())}})
        self.assertEqual(unsigned.json()['code'], 'website_proof_invalid')
        self.assertEqual(self.website('POST', path, secret='x' * 40).json()['code'], 'website_proof_invalid')
        # A raw deletion-style signature does not authorize route access.
        self.assertEqual(self.website('POST', path, key=SECRET.encode()).json()['code'], 'website_proof_invalid')
        self.assertEqual(self.website('POST', path, signed_path='/internal/website/routes').status_code, 401)
        self.assertEqual(self.website('POST', path, issued=self.clock - 61).json()['code'], 'website_proof_expired')
        self.assertEqual(self.website('POST', path, issued=self.clock + 61).json()['code'], 'website_proof_expired')
        self.assertEqual(self.website('POST', path, project='other').json()['code'], 'website_project_mismatch')
        with patch.dict(os.environ, {'BICINO_SOCIAL_DELETION_SECRET': 'short'}):
            self.assertEqual(self.website('POST', path, secret='short').status_code, 503)
        self.assertEqual(self.account_count(), 0)

    def test_signature_covers_the_path_below_the_public_mount(self):
        from fastapi import FastAPI
        root = FastAPI()
        root.mount('/v1/social', self.client.app)
        mounted, self.client = self.client, TestClient(root)
        try:
            imported = self.website('POST', '/v1/social/internal/website/routes',
                                    dict(archive_body(LINE), title='Loop'), signed_path='/internal/website/routes')
            self.assertEqual(imported.status_code, 200, imported.text)
            full = '/v1/social/internal/website/routes/list'
            self.assertEqual(self.website('POST', full).status_code, 401)
            listed = self.website('POST', full, signed_path='/internal/website/routes/list')
            self.assertEqual([item['id'] for item in listed.json()['items']], [imported.json()['id']])
        finally:
            self.client.close()
            self.client = mounted

    def test_listing_never_creates_an_account(self):
        self.assertEqual(self.listed(uid='new-rider'), [])
        self.assertEqual(self.account_count(), 0)

    def test_import_lists_and_shares_storage_with_native_routes(self):
        item = self.imported(elevationGainMeters=2353.4, durationSeconds=14400)
        self.assertEqual(set(item), {'id', 'title', 'visibility', 'revision', 'created', 'provider', 'distanceMeters',
                                     'elevationGainMeters', 'durationSeconds', 'favorite', 'preview', 'sourceURL'})
        self.assertEqual((item['title'], item['visibility'], item['provider'], item['favorite']),
                         ('Sa Calobra loop', 'private', 'user.imported-gpx', False))
        self.assertEqual((item['elevationGainMeters'], item['durationSeconds']), (2353.4, 14400))
        self.assertEqual(item['preview'], website_routes.encode_polyline(LINE))
        self.assertEqual(self.listed(), [item])
        # The iPhone app syncs the same private route through its library API.
        [synced] = self.native('alice', 'GET', '/library/routes').json()['items']
        self.assertEqual((synced['id'], synced['title'], synced['routeRevision'], synced['providerID']),
                         (item['id'], 'Sa Calobra loop', 1, 'user.imported-gpx'))
        self.assertEqual(self.native('alice', 'GET', '/routes').json()['items'], [], 'shared-route list stays separate')
        stored = self.native('alice', 'GET', f"/routes/{item['id']}").json()
        self.assertIn('archive', stored['body'])
        self.assertNotIn('library', stored['body'])
        self.assertEqual(self.native('bob', 'GET', f"/routes/{item['id']}").status_code, 404)
        self.assertEqual(self.listed(uid='bob'), [])

    def test_import_is_idempotent_and_needs_its_nonce_as_key(self):
        body = dict(archive_body(LINE), title='Loop')
        nonce = str(uuid.uuid4())
        first = self.website('POST', '/internal/website/routes', body, nonce=nonce)
        again = self.website('POST', '/internal/website/routes', body, nonce=nonce)
        self.assertEqual(first.status_code, 200, first.text)
        self.assertEqual(first.json(), again.json())
        self.assertEqual(len(self.listed()), 1)
        missing = self.website('POST', '/internal/website/routes', body, idempotency=False)
        self.assertEqual(missing.json()['code'], 'idempotency_key_required')

    def test_import_keeps_native_route_policy(self):
        apple = dict(archive_body(LINE, provider=APPLE), title='Apple')
        self.assertEqual(self.website('POST', '/internal/website/routes', apple).json()['code'],
                         'route_not_redistributable')
        broken = dict(archive_body(LINE), title='Broken')
        broken['hashPayload'] = broken['hashPayload'].replace('Loop', 'Lap')
        self.assertEqual(self.website('POST', '/internal/website/routes', broken).json()['code'],
                         'route_not_redistributable')
        self.assertEqual(self.listed(), [])

    def test_app_library_routes_appear_on_the_website(self):
        self.native('alice', 'GET', '/me')
        gpx = archive_body(LINE)
        gpx_id = json.loads(gpx['archive'])['route']['id']
        self.assertEqual(self.native('alice', 'PUT', f'/library/routes/{gpx_id}', dict(gpx, title='From the app')).status_code, 200)
        strava = archive_body(LINE, provider=STRAVA)
        strava_id = json.loads(strava['archive'])['route']['id']
        put = self.native('alice', 'PUT', f'/library/routes/{strava_id}', dict(strava, title='Strava loop', elevationGainMeters=120.5))
        self.assertEqual(put.status_code, 200, put.text)
        cards = {card['title']: card for card in self.listed()}
        self.assertEqual((cards['From the app']['provider'], cards['From the app']['preview'], cards['From the app']['sourceURL']),
                         ('user.imported-gpx', website_routes.encode_polyline(LINE), None))
        self.assertEqual((cards['Strava loop']['provider'], cards['Strava loop']['sourceURL'], cards['Strava loop']['elevationGainMeters']),
                         ('strava.route', 'https://www.strava.com/routes/3405986242', 120.5))
        self.assertEqual(cards['Strava loop']['preview'], website_routes.encode_polyline(LINE))
        # Shared snapshots are copies of library routes and are not listed twice.
        self.assertEqual(self.native('alice', 'POST', '/routes', dict(archive_body(LINE), title='Snapshot',
                         visibility='private', sharingRightsConfirmed=True)).status_code, 200)
        self.assertEqual(len(self.listed()), 2)

    def test_apple_maps_routes_never_enter_the_library(self):
        self.native('alice', 'GET', '/me')
        apple = archive_body(LINE, provider=APPLE)
        route_id = json.loads(apple['archive'])['route']['id']
        self.assertEqual(self.native('alice', 'PUT', f'/library/routes/{route_id}', dict(apple, title='Apple')).json()['code'],
                         'route_not_redistributable')

    def test_card_fields_stay_with_the_owner_on_every_shared_path(self):
        self.native('alice', 'GET', '/me')
        body = dict(archive_body(LINE), title='Shared', visibility='link', sharingRightsConfirmed=True)
        snapshot = self.native('alice', 'POST', '/routes', body)
        self.assertEqual(snapshot.status_code, 200, snapshot.text)
        self.assertNotIn('website', snapshot.json()['body'])
        link = self.native('alice', 'POST', '/share-links', {'contentID': snapshot.json()['id']}).json()
        shared = self.client.post('/shared/resolve', json={'code': link['url'].split('#')[-1]})
        self.assertEqual(shared.status_code, 200, shared.text)
        self.assertNotIn('website', json.dumps(shared.json()))
        ride = self.native('alice', 'POST', '/group-rides', {'routeID': snapshot.json()['id'], 'title': 'Saturday'})
        self.assertEqual(ride.status_code, 200, ride.text)
        self.assertNotIn('website', json.dumps(ride.json()))
        from map_platform.social.database import rides
        with self.db.transaction() as c:
            self.assertNotIn('website', c.scalar(select(rides.c.route)))
        # Library rows (with duration, star and elevation) can never be shared.
        item = self.imported(elevationGainMeters=812.0, durationSeconds=9876)
        self.assertEqual(self.native('alice', 'PATCH', f"/routes/{item['id']}",
                                     {'revision': 1, 'title': 'Loop', 'visibility': 'link'}).json()['code'],
                         'library_route_private')
        self.assertEqual(self.native('alice', 'POST', '/group-rides', {'routeID': item['id'], 'title': 'Ride'}).json()['code'],
                         'library_route_private')
        self.assertEqual(self.native('alice', 'POST', '/share-links', {'contentID': item['id']}).status_code, 409)
        [card] = self.listed()
        self.assertEqual((card['durationSeconds'], card['elevationGainMeters']), (9876, 812.0))

    def test_listing_reads_card_fields_without_archives(self):
        self.native('alice', 'GET', '/me')
        with self.db.transaction() as c:
            owner = c.scalar(select(accounts.c.id).where(accounts.c.uid == 'alice'))
            c.execute(content.insert().values(
                id=str(uuid.uuid4()), owner=owner, kind='route', title='Before cards', visibility='private',
                revision=1, created=self.clock - 10, source='library:' + str(uuid.uuid4()).upper(), fingerprint='0' * 64,
                body={'archive': 'not json', 'sha256': '0' * 64, 'hashPayload': '{}', 'distanceMeters': 1234.5}))
        item = self.imported()
        listed = self.listed()
        self.assertEqual([entry['id'] for entry in listed][0], item['id'])
        legacy = listed[1]
        self.assertEqual((legacy['title'], legacy['distanceMeters'], legacy['provider'], legacy['preview'], legacy['favorite']),
                         ('Before cards', 1234.5, None, None, False))

    def test_rename_star_and_delete(self):
        item = self.imported()
        path = f"/internal/website/routes/{item['id']}"
        starred = self.website('PATCH', path, {'favorite': True})
        self.assertEqual(starred.status_code, 200, starred.text)
        self.assertEqual((starred.json()['favorite'], starred.json()['revision']), (True, 1))
        self.assertEqual(self.website('PATCH', path, {'title': 'Renamed'}).json()['code'], 'revision_required')
        self.assertEqual(self.website('PATCH', path, {}).json()['code'], 'nothing_to_change')
        renamed = self.website('PATCH', path, {'title': 'Renamed', 'revision': 1})
        self.assertEqual((renamed.json()['title'], renamed.json()['revision'], renamed.json()['favorite']),
                         ('Renamed', 2, True))
        self.assertEqual(self.website('PATCH', path, {'title': 'Stale', 'revision': 1}).json()['code'],
                         'version_conflict')
        self.assertEqual(self.native('alice', 'GET', f"/routes/{item['id']}").json()['title'], 'Renamed')
        self.assertEqual(self.website('PATCH', path, {'favorite': True}, uid='bob').status_code, 404)
        self.assertEqual(self.website('DELETE', path, uid='bob').status_code, 404)
        deleted = self.website('DELETE', path)
        self.assertEqual(deleted.json(), {'deleted': True})
        self.assertEqual(self.listed(), [])
        self.assertEqual(self.website('DELETE', path).status_code, 404)

    def test_route_paths_never_touch_activities(self):
        self.native('alice', 'GET', '/me')
        activity = self.native('alice', 'POST', '/activities', {
            'title': 'Ride', 'sourceID': 'workout-1', 'movingSeconds': 60, 'elapsedSeconds': 60,
            'uploadConsent': True, 'points': [{'latitude': lat, 'longitude': lon} for lat, lon in LINE]})
        self.assertEqual(activity.status_code, 200, activity.text)
        path = f"/internal/website/routes/{activity.json()['id']}"
        self.assertEqual(self.website('DELETE', path).status_code, 404)
        self.assertEqual(self.website('PATCH', path, {'favorite': True}).status_code, 404)
        with self.db.transaction() as c:
            self.assertEqual(c.scalar(select(func.count()).select_from(content)), 1)

    def test_rollback_hides_the_library_but_keeps_deletion(self):
        item = self.imported()
        self.client.app.state.features = SocialFeatures(media=True)
        self.assertEqual(self.website('POST', '/internal/website/routes/list').status_code, 503)
        self.assertEqual(self.website('POST', '/internal/website/routes',
                                      dict(archive_body(LINE), title='Loop')).status_code, 503)
        self.assertEqual(self.website('DELETE', f"/internal/website/routes/{item['id']}").status_code, 200)


class PreviewTest(unittest.TestCase):
    def test_polyline_matches_the_published_example(self):
        points = [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]
        self.assertEqual(website_routes.encode_polyline(points), '_p~iF~ps|U_ulLnnqC_mqNvxq`@')

    def test_preview_work_is_bounded_for_adversarial_geometry(self):
        import math, time
        spiral = [(1.3 + 0.01 * (i / 60000) * math.cos(i / 7), 103.8 + 0.01 * (i / 60000) * math.sin(i / 7))
                  for i in range(60000)]
        started = time.perf_counter()
        simplified = website_routes._simplify(spiral, website_routes.PREVIEW_MAX_POINTS)
        self.assertLess(time.perf_counter() - started, 2.0)
        self.assertEqual(len(simplified), website_routes.PREVIEW_MAX_POINTS)
        self.assertEqual((simplified[0], simplified[-1]), (spiral[0], spiral[-1]))

    def test_long_routes_are_simplified_to_the_card_limit(self):
        points = [(46.5 + 0.0001 * i, 11.7 + 0.002 * ((i // 50) % 2) * (i % 50) / 50) for i in range(20000)]
        simplified = website_routes._simplify(points, website_routes.PREVIEW_MAX_POINTS)
        self.assertLessEqual(len(simplified), website_routes.PREVIEW_MAX_POINTS)
        self.assertEqual((simplified[0], simplified[-1]), (points[0], points[-1]))


if __name__ == '__main__':
    unittest.main()
