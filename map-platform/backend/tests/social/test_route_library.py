import json
import unittest
import uuid
from unittest.mock import patch

from sqlalchemy import select

from map_platform.social.database import accounts, exposures
from map_platform.social.features import SocialFeatures
from map_platform.social.route_archive import route_fingerprint
from map_platform.social.service import SocialService

try:
    from tests.social.test_website_routes import APPLE, LINE, STRAVA, RouteStoreCase, archive_body
except ImportError:  # `unittest discover -s tests/social` imports siblings top-level.
    from test_website_routes import APPLE, LINE, STRAVA, RouteStoreCase, archive_body


def body_for(archive, title='Loop', **extra):
    return dict(archive, title=title, **extra)


def route_id_of(archive):
    return json.loads(archive['archive'])['route']['id']


class RouteLibraryTest(RouteStoreCase):
    """The app's private route library, synced by route ID."""

    def setUp(self):
        super().setUp()
        self.native('alice', 'GET', '/me')
        self.native('bob', 'GET', '/me')

    def put(self, archive, who='alice', route_id=None, **extra):
        return self.native(who, 'PUT', f"/library/routes/{route_id or route_id_of(archive)}", body_for(archive, **extra))

    def library(self, who='alice'):
        response = self.native(who, 'GET', '/library/routes')
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()['items']

    def test_upsert_lists_lean_rows_and_only_titles_change_for_identical_content(self):
        archive = archive_body(LINE)
        route_id = route_id_of(archive)
        first = self.put(archive, title='Morning loop')
        self.assertEqual(first.status_code, 200, first.text)
        self.assertEqual(set(first.json()), {'id', 'routeID', 'title', 'revision', 'created', 'contentHash',
                                             'routeRevision', 'providerID'})
        self.assertEqual((first.json()['routeID'], first.json()['revision']), (route_id, 1))
        [row] = self.library()
        self.assertEqual(row, first.json())
        self.assertNotIn('archive', json.dumps(row))
        again = self.put(archive, title='Morning loop')
        self.assertEqual(again.json(), first.json())
        renamed = self.put(archive, title='Evening loop')
        self.assertEqual((renamed.json()['id'], renamed.json()['title'], renamed.json()['revision']),
                         (first.json()['id'], 'Evening loop', 2))
        self.assertEqual(len(self.library()), 1)
        lower = self.native('alice', 'PUT', f"/library/routes/{route_id.lower()}", body_for(archive, title='Evening loop'))
        self.assertEqual(lower.json()['id'], first.json()['id'], 'route IDs are case-insensitive')
        self.assertEqual(self.put(archive, route_id=str(uuid.uuid4())).json()['code'], 'route_id_mismatch')
        self.assertEqual(self.native('alice', 'PUT', '/library/routes/not-a-uuid', body_for(archive)).status_code, 404)

    def test_strava_routes_are_kept_privately_without_expiry(self):
        strava = archive_body(LINE, provider=STRAVA)
        self.assertEqual(self.put(strava, title='Strava loop').status_code, 200)
        self.assertEqual(self.native('alice', 'POST', '/routes', dict(strava, title='x', visibility='private',
                         sharingRightsConfirmed=True)).json()['code'], 'route_not_redistributable',
                         'Strava archives never become shared snapshots')
        self.clock += 30 * 86400  # Long past the archive's seven-day deleteAfter.
        [row] = self.library()
        stored = self.native('alice', 'GET', f"/routes/{row['id']}").json()
        self.assertEqual(json.loads(stored['body']['archive'])['route']['sourceReference']['externalRouteID'], '3405986242')
        for change in ({'canonicalURL': 'https://evil.example/routes/3405986242'}, {'externalRouteID': '012'},
                       {'providerID': 'user.imported-gpx'}):
            archive = json.loads(archive_body(LINE, provider=STRAVA)['archive'])
            archive['route']['sourceReference'].update(change)
            del archive['contentHash']
            payload = json.dumps(archive, separators=(',', ':'), sort_keys=True)
            import hashlib
            archive['contentHash'] = hashlib.sha256(payload.encode()).hexdigest()
            bad = {'archive': json.dumps(archive), 'hashPayload': payload}
            self.assertEqual(self.put(bad).json()['code'], 'route_not_redistributable', change)

    def test_newer_revisions_replace_and_older_ones_are_refused(self):
        route_id = str(uuid.uuid4()).upper()
        self.assertEqual(self.put(archive_body(LINE, provider=STRAVA, route_id=route_id, revision=1)).status_code, 200)
        [row] = self.library()
        self.assertEqual(self.website('PATCH', f"/internal/website/routes/{row['id']}", {'favorite': True}).status_code, 200)
        reloaded = self.put(archive_body(LINE[:3], provider=STRAVA, route_id=route_id, revision=2), elevationGainMeters=40)
        self.assertEqual(reloaded.status_code, 200, reloaded.text)
        self.assertEqual((reloaded.json()['id'], reloaded.json()['routeRevision'], reloaded.json()['revision']),
                         (row['id'], 2, 2))
        [card] = self.listed()
        self.assertEqual((card['favorite'], card['elevationGainMeters']), (True, 40), 'the star survives a reload')
        stale = self.put(archive_body(LINE, provider=STRAVA, route_id=route_id, revision=1))
        self.assertEqual(stale.json()['code'], 'stale_route_revision')

    def test_rename_delete_and_account_isolation(self):
        archive = archive_body(LINE)
        route_id = route_id_of(archive)
        self.assertEqual(self.put(archive).status_code, 200)
        renamed = self.native('alice', 'PATCH', f'/library/routes/{route_id}', {'title': 'Col de la Madeleine'})
        self.assertEqual((renamed.json()['title'], renamed.json()['revision']), ('Col de la Madeleine', 2))
        self.assertEqual(self.library('bob'), [])
        self.assertEqual(self.native('bob', 'PATCH', f'/library/routes/{route_id}', {'title': 'x'}).status_code, 404)
        self.assertEqual(self.native('bob', 'DELETE', f'/library/routes/{route_id}').status_code, 404)
        [row] = self.library()
        self.assertEqual(self.native('bob', 'GET', f"/routes/{row['id']}").status_code, 404)
        # Bob's own copy of the same route ID is a separate row.
        self.assertEqual(self.put(archive, who='bob').status_code, 200)
        self.assertEqual(self.native('alice', 'DELETE', f'/library/routes/{route_id}').json(), {'deleted': True})
        self.assertEqual(self.library(), [])
        self.assertEqual(len(self.library('bob')), 1)
        self.assertEqual(self.native('alice', 'DELETE', f'/library/routes/{route_id}').status_code, 404)

    def test_private_copies_of_received_routes_are_allowed_but_not_republished(self):
        archive = archive_body(LINE)
        points = json.loads(archive['archive'])['route']['points']
        with self.db.transaction() as c:
            alice = c.scalar(select(accounts.c.id).where(accounts.c.uid == 'alice'))
            bob = c.scalar(select(accounts.c.id).where(accounts.c.uid == 'bob'))
            c.execute(exposures.insert().values(viewer=bob, fingerprint=route_fingerprint(points), owner=alice,
                                                created=self.clock))
        self.assertEqual(self.put(archive, who='bob').status_code, 200, 'a saved copy may sync privately')
        published = self.native('bob', 'POST', '/routes', dict(archive, title='x', visibility='friends',
                                                               sharingRightsConfirmed=True))
        self.assertEqual(published.json()['code'], 'route_redistribution_not_permitted')

    def test_apple_maps_and_rollback(self):
        self.assertEqual(self.put(archive_body(LINE, provider=APPLE)).json()['code'], 'route_not_redistributable')
        archive = archive_body(LINE)
        self.assertEqual(self.put(archive).status_code, 200)
        self.assertTrue(self.native('alice', 'GET', '/capabilities').json()['routeLibrary'])
        self.client.app.state.features = SocialFeatures(media=True)
        self.assertFalse(self.native('alice', 'GET', '/capabilities').json()['routeLibrary'])
        self.assertEqual(self.native('alice', 'GET', '/library/routes').status_code, 503)
        self.assertEqual(self.put(archive_body(LINE)).status_code, 503)
        self.assertEqual(self.native('alice', 'DELETE', f'/library/routes/{route_id_of(archive)}').status_code, 200)

    def test_quota_and_idempotent_replay(self):
        with patch.object(SocialService, 'LIBRARY_QUOTA', 1):
            self.assertEqual(self.put(archive_body(LINE)).status_code, 200)
            self.assertEqual(self.put(archive_body(LINE)).json()['code'], 'content_quota')
        archive = archive_body(LINE)
        path = f"/library/routes/{route_id_of(archive)}"
        headers = {'Authorization': 'Bearer alice', 'Idempotency-Key': 'library-put-1'}
        first = self.client.put(path, json=body_for(archive), headers=headers)
        again = self.client.put(path, json=body_for(archive), headers=headers)
        self.assertEqual((first.status_code, again.json()), (200, first.json()))
        self.assertEqual(self.client.put(path, json=body_for(archive, title='Other'), headers=headers).json()['code'],
                         'idempotency_conflict')


if __name__ == '__main__':
    unittest.main()
