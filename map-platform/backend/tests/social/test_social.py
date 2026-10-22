import base64
import hashlib
import json
import unittest
import os
import uuid
from io import BytesIO
from unittest.mock import patch
from PIL import Image
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.exc import OperationalError
from map_platform.social.api import create_app
from map_platform.social.features import SocialFeatures
from map_platform.social.database import Database, accounts, content, devices, invites, media, members, outbox
from map_platform.social.media import MemoryMedia, sanitize_avatar
from map_platform.social.service import SocialService
from map_platform.social.worker import cleanup_account, run_once
from map_platform.social.geometry import distance, sanitize_track, route_progress
from map_platform.user_auth import AccountPrincipal

class Identity:
    project = "test"
    def verify(self, token):
        if token not in {'alice','bob','carol'}: raise ValueError()
        return AccountPrincipal('test',token,1000000)
    def delete(self, uid): pass
    def revoke_apple(self, uid, code): pass

class Notifications:
    def send(self, *args): return True

class SocialTest(unittest.TestCase):
    def setUp(self):
        self.clock=1000000.
        url=os.environ.get('BICINO_SOCIAL_TEST_DATABASE_URL','sqlite://')
        if url != 'sqlite://':
            if not url.endswith('/social_test') or '@127.0.0.1:' not in url: raise ValueError('isolated social_test database required')
        self.db=Database(url,testing=True)
        if url != 'sqlite://':
            from map_platform.social.database import metadata
            metadata.drop_all(self.db.engine)
        self.db.migrate()
        self.media=MemoryMedia();self.service=SocialService(self.db,self.media,lambda:self.clock)
        self.client=TestClient(create_app(service=self.service,identity=Identity(),features=SocialFeatures(True,True,True,True,True)))
        self.counter=0
        self.consentEpochs={}
        self.deletionReceipts={}
        self.ids={u:self.call(u,'GET','/me').json()['id'] for u in ('alice','bob','carol')}
    def test_invite_preview_is_view_only_and_ends_with_ride(self):
        self.client.app.state.features = SocialFeatures(True, True, True, True, True, True)
        route = self.call('alice', 'POST', '/routes', self.route()).json()
        ride = self.call('alice', 'POST', '/group-rides', {'routeID': route['id'], 'title': 'Morning loop'}).json()
        buffer = BytesIO(); Image.new('RGB', (1200,630), 'blue').save(buffer, format='PNG')
        data = buffer.getvalue()
        path = f"/group-rides/{ride['id']}/invite-preview"
        def upload(who='alice', key='preview-one', image=data):
            return self.client.put(path, content=image, headers={'Authorization':'Bearer '+who, 'Idempotency-Key':key, 'Content-Type':'image/png'})
        self.assertEqual(upload('bob').status_code,404)
        self.assertEqual(upload(key='invalid-image', image=b'not an image').status_code,400)
        result = upload(); self.assertEqual(result.status_code,200,result.text)
        preview = result.json()['previewID']
        public = f'/ride-previews/{preview}'
        metadata = self.client.get(public)
        self.assertEqual(metadata.status_code,200,metadata.text)
        self.assertEqual(set(metadata.json()), {'previewID','title','distanceMeters','imageSHA256','expiresAt'})
        self.assertEqual(metadata.json()['title'],'Morning loop')
        self.assertNotIn(ride['joinCode'],metadata.text)
        image = self.client.get(public+'/image')
        self.assertEqual(image.status_code,200,image.text if image.status_code!=200 else '')
        self.assertEqual(image.headers['content-type'],'image/png')
        self.assertEqual(hashlib.sha256(image.content).hexdigest(),metadata.json()['imageSHA256'])
        self.assertEqual(image.headers['cache-control'],'no-store')
        self.assertEqual(Image.open(BytesIO(image.content)).size,(1200,630))
        self.assertEqual(upload().json()['previewID'],preview,'idempotent replay keeps the same card')
        new = upload(key='preview-two').json()['previewID']
        self.assertNotEqual(new,preview)
        self.assertEqual(self.client.get(public).status_code,404)
        self.assertEqual(self.client.get(public+'/image').status_code,404)
        self.assertEqual(self.call('alice','POST',f"/group-rides/{ride['id']}/end").status_code,200)
        self.assertEqual(self.client.get(f'/ride-previews/{new}').status_code,404)
        run_once(self.db,Identity(),self.media,Notifications(),self.clock)
        self.assertFalse(any('/'+asset+'/' in key for key in self.media.objects for asset in (preview,new)), 'ended preview media is removed by the worker')

    def test_invite_preview_rollout_and_expiry(self):
        self.assertEqual(self.client.get('/ride-previews/'+str(uuid.uuid4())).status_code,503)
        self.client.app.state.features = SocialFeatures(True, True, True, True, True, True)
        route = self.call('alice','POST','/routes',self.route()).json()
        ride = self.call('alice','POST','/group-rides',{'routeID':route['id'],'title':'Ride'}).json()
        buffer=BytesIO(); Image.new('RGB',(1200,630),'white').save(buffer,format='PNG')
        response=self.client.put(f"/group-rides/{ride['id']}/invite-preview",content=buffer.getvalue(),headers={'Authorization':'Bearer alice','Idempotency-Key':'preview-expiry','Content-Type':'image/png'})
        preview=response.json()['previewID']
        self.clock += 86401
        self.assertEqual(self.client.get(f'/ride-previews/{preview}').status_code,404)
        run_once(self.db,Identity(),self.media,Notifications(),self.clock)
        run_once(self.db,Identity(),self.media,Notifications(),self.clock)
        self.assertFalse(self.media.objects)

    def tearDown(self):
        self.client.close(); self.db.engine.dispose()
    def call(self, who, method, path, body=None, key=None, **kwargs):
        self.counter+=1
        headers={'Authorization':'Bearer '+who,'Idempotency-Key':key or 'request-'+str(self.counter)}
        if method == 'POST' and path.endswith('/consent') and isinstance(body,dict) and 'epoch' not in body:
            receipt=(who,path,headers['Idempotency-Key'])
            if receipt not in self.consentEpochs:
                with self.db.transaction() as c:
                    self.consentEpochs[receipt]=c.scalar(select(members.c.epoch).where(
                        (members.c.ride==path.split('/')[2]) & (members.c.account==self.ids[who])))
            if self.consentEpochs[receipt]: body=dict(body,epoch=self.consentEpochs[receipt])
        if method == 'POST' and path == '/me/deletion' and isinstance(body,dict) and 'receiptDigest' not in body:
            # Mirrors the app: a fresh client-held receipt secret per deletion request.
            secret=self.secret()
            self.deletionReceipts[who]=secret
            body=dict(body,receiptDigest=hashlib.sha256(secret.encode()).hexdigest())
        return self.client.request(method,path,json=body,headers=headers,**kwargs)
    @staticmethod
    def secret():
        return base64.urlsafe_b64encode(os.urandom(32)).rstrip(b'=').decode()
    def device(self, owner, token='a'*64, installation=None, secret=None):
        """Insert a proven installation binding directly, as the worker would see it."""
        installation = installation or str(uuid.uuid4())
        with self.db.transaction() as c:
            c.execute(devices.insert().values(id=installation, owner=owner, token=token, environment='development',
                secret_digest=hashlib.sha256((secret or self.secret()).encode()).hexdigest()))
        return installation
    def friend(self):
        r=self.call('alice','POST','/friend-requests',{'profileID':self.ids['bob']})
        self.assertEqual(r.status_code,200,r.text)
        r=self.call('bob','POST',f"/friend-requests/{r.json()['id']}/accept")
        self.assertEqual(r.status_code,200,r.text)
    def route(self, visibility='friends', provider=None):
        archive={'schemaVersion':1,'createdAt':1000000000,'route':{
            'id':'00000000-0000-4000-8000-000000000001','revision':1,
            'provider':provider or {'providerID':'user.imported-gpx','attribution':'User-provided GPX','storageScope':'durable'},
            'localeIdentifier':'en_US','transportType':'cycling','normalizationVersion':1,
            'source':{'coordinate':{'latitude':0,'longitude':0},'label':'Start'},
            'destination':{'coordinate':{'latitude':0,'longitude':0.05},'label':'End'},
            'bounds':{'south':0,'west':0,'north':0,'east':0.05},'distanceMeters':5560,
            'points':[{'latitude':0,'longitude':0},{'latitude':0,'longitude':0.025},{'latitude':0,'longitude':0.05}],'steps':[{'id':1,'geometryStartIndex':0,'geometryEndIndex':2,'instruction':'Follow route','maneuver':'straight','distanceMeters':5560}]}}
        payload=json.dumps(archive,separators=(',',':'),sort_keys=True)
        archive['contentHash']=hashlib.sha256(payload.encode()).hexdigest()
        return {'title':'Ride','visibility':visibility,'archive':json.dumps(archive),'hashPayload':payload,'sharingRightsConfirmed':True}
    def route_body(self, points, route_id, visibility='friends'):
        """A valid imported-GPX archive with chosen geometry and route identity."""
        coordinates=[{'latitude':lat,'longitude':lon} for lat,lon in points]
        archive={'schemaVersion':1,'createdAt':1000000000,'route':{
            'id':route_id,'revision':1,
            'provider':{'providerID':'user.imported-gpx','attribution':'User-provided GPX','storageScope':'durable'},
            'localeIdentifier':'en_US','transportType':'cycling','normalizationVersion':1,
            'source':{'coordinate':coordinates[0],'label':'Start'},
            'destination':{'coordinate':coordinates[-1],'label':'End'},
            'bounds':{'south':min(p[0] for p in points),'west':min(p[1] for p in points),
                      'north':max(p[0] for p in points),'east':max(p[1] for p in points)},
            'distanceMeters':2000,'points':coordinates,
            'steps':[{'id':1,'geometryStartIndex':0,'geometryEndIndex':len(points)-1,'instruction':'Follow route',
                      'maneuver':'straight','distanceMeters':2000}]}}
        payload=json.dumps(archive,separators=(',',':'),sort_keys=True)
        archive['contentHash']=hashlib.sha256(payload.encode()).hexdigest()
        return {'title':'Ride','visibility':visibility,'archive':json.dumps(archive),'hashPayload':payload,'sharingRightsConfirmed':True}
    def ride(self):
        self.friend()
        route=self.call('alice','POST','/routes',self.route()).json()
        r=self.call('alice','POST','/group-rides',{'routeID':route['id'],'title':'Saturday'})
        self.assertEqual(r.status_code,200,r.text)
        room=r.json()
        joined=self.call('bob','POST','/group-rides/join',{'code':room['joinCode']})
        self.assertEqual(joined.status_code,200,joined.text)
        self.assertFalse(joined.json()['sharing'])
        return room
    def enable_friend_sharing(self, who='alice', target='bob', enabled=True, stats=True, key=None):
        path = f'/friend-sharing/{self.ids[target]}/consent'
        current = self.call(who, 'GET', path)
        self.assertEqual(current.status_code, 200, current.text)
        return self.call(who, 'POST', path, {'epoch': current.json()['epoch'],
                         'location': enabled, 'stats': enabled and stats}, key=key)

    def friend_state(self, epochs, sequence=0):
        return {'epochs': epochs, 'sequence': sequence, 'latitude': 1, 'longitude': 2,
                'capturedAt': self.clock, 'horizontalAccuracy': 5, 'speed': 6,
                'distanceMeters': 1234, 'movingSeconds': 60, 'elapsedSeconds': 90}

    def test_friend_sharing_is_directional_route_independent_and_bounded(self):
        self.friend(); self.client.app.state.features = SocialFeatures(friendSharing=True)
        consent = self.enable_friend_sharing().json()
        self.assertTrue(consent['sharing'])
        self.assertEqual(consent['sharingExpiresAt']-self.clock, 4*3600)
        state = self.friend_state({self.ids['bob']: consent['epoch']})
        self.assertEqual(self.call('alice', 'POST', '/friend-sharing/state', state).json()['accepted'], [self.ids['bob']])
        bob = self.call('bob', 'GET', '/friend-sharing').json()
        self.assertEqual(bob['outgoing'], [])
        rider = bob['riders'][0]
        self.assertEqual(rider['profile']['id'], self.ids['alice'])
        self.assertEqual(rider['speed'], 6)
        self.assertNotIn('epochs', rider); self.assertNotIn('routeHash', rider)
        self.assertEqual(self.call('alice', 'GET', '/friend-sharing').json()['riders'], [])
        self.assertEqual(self.call('carol', 'GET', '/friend-sharing').json()['riders'], [])
        self.clock += 61
        self.assertEqual(self.call('bob', 'GET', '/friend-sharing').json()['riders'], [])
        self.clock += 4*3600
        state.update(capturedAt=self.clock, sequence=1)
        self.assertEqual(self.call('alice', 'POST', '/friend-sharing/state', state).json()['accepted'], [])
        self.assertEqual(self.call('alice', 'GET', '/friend-sharing').json()['outgoing'], [])

    def test_friend_sharing_stop_epochs_replays_and_rollout(self):
        self.friend(); self.client.app.state.features = SocialFeatures(friendSharing=True)
        path = f"/friend-sharing/{self.ids['bob']}/consent"
        initial = self.call('alice', 'GET', path).json()
        request = {'epoch': initial['epoch'], 'location': True, 'stats': True}
        start = self.call('alice', 'POST', path, request, key='friend-share-start').json()
        old = self.friend_state({self.ids['bob']: start['epoch']})
        self.call('alice', 'POST', '/friend-sharing/state', old)
        self.enable_friend_sharing(enabled=False)
        self.assertEqual(self.call('alice', 'POST', '/friend-sharing/state', old).json()['accepted'], [])
        replay = self.call('alice', 'POST', path, request, key='friend-share-start').json()
        self.assertFalse(replay['sharing']); self.assertNotEqual(replay['epoch'], start['epoch'])
        self.enable_friend_sharing()
        self.enable_friend_sharing('bob', 'alice')
        self.assertEqual(self.call('alice', 'DELETE', '/friend-sharing').status_code, 200)
        self.assertEqual(self.call('alice', 'GET', '/friend-sharing').json()['outgoing'], [])
        self.assertEqual(len(self.call('bob', 'GET', '/friend-sharing').json()['outgoing']), 1)
        self.assertEqual(self.call('alice', 'POST', '/friend-sharing/state', old).json()['accepted'], [])
        self.enable_friend_sharing()
        self.client.app.state.features = SocialFeatures()
        self.assertEqual(self.call('alice', 'GET', '/friend-sharing').status_code, 503)
        self.assertEqual(self.call('alice', 'POST', '/friend-sharing/state', old).status_code, 503)
        stopped = self.enable_friend_sharing(enabled=False)
        self.assertEqual(stopped.status_code, 200, stopped.text)
        self.assertFalse(stopped.json()['sharing'])

    def test_friend_sharing_unfriend_block_and_readd_never_resumes(self):
        self.friend(); self.client.app.state.features = SocialFeatures(friendSharing=True)
        a = self.enable_friend_sharing().json()
        self.enable_friend_sharing('bob', 'alice')
        state = self.friend_state({self.ids['bob']: a['epoch']})
        self.call('alice', 'POST', '/friend-sharing/state', state)
        self.call('alice', 'DELETE', f"/friends/{self.ids['bob']}")
        self.assertEqual(self.call('bob', 'GET', '/friend-sharing').json()['riders'], [])
        from map_platform.social.database import friend_shares
        with self.db.transaction() as c:
            self.assertEqual(c.execute(select(friend_shares)).all(), [])
        self.clock += 86401
        state['capturedAt'] = self.clock
        self.friend()
        self.assertFalse(self.call('alice', 'GET', f"/friend-sharing/{self.ids['bob']}/consent").json()['sharing'])
        self.assertEqual(self.call('alice', 'POST', '/friend-sharing/state', state).json()['accepted'], [])
        self.enable_friend_sharing()
        self.call('bob', 'PUT', f"/blocks/{self.ids['alice']}")
        self.assertEqual(self.call('alice', 'GET', '/friend-sharing').json()['outgoing'], [])
        self.assertEqual(self.call('bob', 'GET', '/friend-sharing').json()['riders'], [])
        self.assertEqual(self.call('alice', 'GET', f"/friend-sharing/{self.ids['carol']}/consent").status_code, 403)

    def test_friend_sharing_batch_isolates_stats_and_rejects_stale_fixes(self):
        self.friend()
        request = self.call('alice', 'POST', '/friend-requests', {'profileID': self.ids['carol']}).json()
        self.call('carol', 'POST', f"/friend-requests/{request['id']}/accept")
        self.client.app.state.features = SocialFeatures(friendSharing=True)
        a = self.enable_friend_sharing().json()
        c = self.enable_friend_sharing(target='carol', stats=False).json()
        state = self.friend_state({self.ids['bob']: a['epoch'], self.ids['carol']: c['epoch']})
        self.assertEqual(self.call('alice', 'POST', '/friend-sharing/state', dict(state, capturedAt=self.clock-31)).status_code, 409)
        self.assertEqual(len(self.call('alice', 'POST', '/friend-sharing/state', state).json()['accepted']), 2)
        bob = self.call('bob', 'GET', '/friend-sharing').json()['riders'][0]
        carol = self.call('carol', 'GET', '/friend-sharing').json()['riders'][0]
        self.assertIn('speed', bob); self.assertNotIn('speed', carol); self.assertNotIn('distanceMeters', carol)
        state['sequence'] = 1
        self.assertEqual(self.call('alice', 'POST', '/friend-sharing/state', state).status_code, 429)
        self.clock += 3; state['capturedAt'] = self.clock
        state['epochs'][self.ids['bob']] = str(uuid.uuid4())
        self.assertEqual(self.call('alice', 'POST', '/friend-sharing/state', state).json()['accepted'], [self.ids['carol']])
        self.call('alice', 'POST', '/me/deletion', {'expectedProfileID': self.ids['alice']})
        self.assertEqual(self.call('carol', 'GET', '/friend-sharing').json()['riders'], [])

    def test_friend_sharing_schema_upgrade_creates_no_implicit_consents(self):
        from map_platform.social.database import versions, friend_shares
        from sqlalchemy import update
        self.friend()
        with self.db.transaction() as c: c.execute(update(versions).values(version=3))
        friend_shares.drop(self.db.engine)
        with self.assertRaises(ValueError): self.db.check_schema()
        self.db.migrate(); self.db.check_schema()
        self.client.app.state.features = SocialFeatures(friendSharing=True)
        self.assertEqual(self.call('alice', 'GET', '/friend-sharing').json()['outgoing'], [])
        self.assertEqual(self.call('bob', 'GET', '/friend-sharing').json()['riders'], [])

    def test_identity_and_no_personal_identifiers(self):
        self.assertEqual(self.client.get('/me').status_code,401)
        profile=self.call('alice','GET','/me').json()
        self.assertEqual(profile['privacy']['zones'],[])
        self.assertNotIn('uid',profile);self.assertNotIn('email',profile)
        self.assertNotEqual(profile['id'],'alice')

    def test_rollout_defaults_keep_accounts_and_cleanup_available(self):
        from unittest.mock import patch
        with patch.dict(os.environ, {}, clear=True):
            features = SocialFeatures.from_environment()
        self.assertEqual(features.document(), dict(media=False, routes=False, activities=False, groups=False, hardware=False, invitePreviews=False, savedMapKitRoutes=False, friendSharing=False))
        self.client.app.state.features = features
        self.assertEqual(self.call('alice', 'GET', '/capabilities').json(), features.document())
        self.assertEqual(self.call('alice', 'GET', '/me').status_code, 200)
        self.friend()
        self.assertEqual(self.call('alice', 'POST', '/routes', self.route()).status_code, 503)
        self.assertEqual(self.call('alice', 'GET', '/activities').status_code, 503)
        self.assertEqual(self.call('alice', 'GET', '/group-rides').status_code, 503)
        self.assertEqual(self.call('alice', 'DELETE', '/me/avatar').status_code, 200)
        self.assertEqual(self.call('alice', 'POST', '/me/deletion', {'expectedProfileID': self.ids['alice']}).status_code, 200)
        with patch.dict(os.environ, {'BICINO_SOCIAL_FEATURE_ROUTES': 'tru'}, clear=True):
            with self.assertRaises(ValueError): SocialFeatures.from_environment()

    def test_rollout_blocks_links_aliases_and_idempotent_replay(self):
        item = self.call('alice', 'POST', '/routes', self.route('link')).json()
        link = self.call('alice', 'POST', '/share-links', {'contentID': item['id']}, key='rollout-link').json()
        self.client.app.state.features = SocialFeatures(activities=True, groups=True, hardware=True)
        caps = self.call('alice', 'GET', '/capabilities').json()
        self.assertFalse(caps['groups']); self.assertFalse(caps['hardware'])
        for path in ['/routes/' + item['id'], '/activities/' + item['id'], '/shared/resolve']:
            self.assertEqual((self.client.post(path, json={'code':link['url'].split('#')[-1]}) if path == '/shared/resolve' else self.call('alice', 'GET', path)).status_code, 503, path)
        self.assertEqual(self.call('alice', 'POST', '/share-links', {'contentID': item['id']}, key='rollout-link').status_code, 503)
        self.assertEqual(self.call('alice', 'POST', '/share-links', {'contentID': item['id']}).status_code, 503)
        self.assertEqual(self.call('alice', 'DELETE', '/share-links/' + link['id']).status_code, 200)
        self.assertEqual(self.call('alice', 'DELETE', '/routes/' + item['id']).status_code, 200)

    def test_rollout_closes_existing_socket_and_preserves_stop_and_leave(self):
        from starlette.websockets import WebSocketDisconnect
        room = self.ride(); rid = room['id']
        self.call('bob', 'POST', f'/group-rides/{rid}/consent', {'location': True, 'stats': True})
        with self.client.websocket_connect(f'/group-rides/{rid}/live', headers={'Authorization': 'Bearer bob'}) as socket:
            self.assertTrue(socket.receive_json()['capabilities']['hardware'])
            self.client.app.state.features = SocialFeatures(routes=True)
            with self.assertRaises(WebSocketDisconnect) as closed: socket.receive_json()
            self.assertEqual(closed.exception.code, 4003)
        self.assertEqual(self.call('bob', 'POST', f'/group-rides/{rid}/consent', {'location': True, 'stats': False}).status_code, 503)
        self.assertEqual(self.call('bob', 'POST', f'/group-rides/{rid}/consent', {'location': False, 'stats': False}).status_code, 200)
        self.assertEqual(self.call('bob', 'POST', f'/group-rides/{rid}/leave').status_code, 200)
        self.assertEqual(self.call('alice', 'POST', f'/group-rides/{rid}/end').status_code, 200)
    def test_requests_require_recipient_acceptance_and_block_revokes(self):
        r=self.call('alice','POST','/friend-requests',{'profileID':self.ids['bob']})
        key=r.json()['id']
        self.assertEqual(self.call('alice','POST',f'/friend-requests/{key}/accept').status_code,409)
        reverse=self.call('bob','POST','/friend-requests',{'profileID':self.ids['alice']}).json()
        self.assertEqual(reverse['status'],'pending')
        self.assertEqual(self.call('bob','POST',f'/friend-requests/{key}/accept').status_code,200)
        self.assertEqual(len(self.call('alice','GET','/friends').json()['items']),1)
        self.call('bob','PUT',f"/blocks/{self.ids['alice']}")
        self.assertEqual(self.call('alice','GET',f"/profiles/{self.ids['bob']}").status_code,404)
        self.assertEqual(self.call('alice','GET','/friends').json()['items'],[])
        self.call('bob','DELETE',f"/blocks/{self.ids['alice']}")
        self.assertEqual(self.call('alice','GET','/friends').json()['items'],[])
    def test_routes_permissions_and_revocation(self):
        self.friend()
        item=self.call('alice','POST','/routes',self.route(),key='route-create').json()
        self.assertEqual(self.call('bob','GET','/routes/'+item['id']).status_code,200)
        self.assertEqual(self.call('carol','GET','/routes/'+item['id']).status_code,404)
        self.call('alice','DELETE',f"/friends/{self.ids['bob']}")
        self.assertEqual(self.call('bob','GET','/routes/'+item['id']).status_code,404)
        wrong=self.route();wrong['title']='Other'
        self.assertEqual(self.call('alice','POST','/routes',wrong,key='route-create').status_code,409)
        raw=self.route();archive=json.loads(raw['archive']);archive['route']['provider']['providerID']='apple.mapkit'
        raw['archive']=json.dumps(archive)
        self.assertEqual(self.call('alice','POST','/routes',raw).status_code,400)

    def test_saved_mapkit_exact_route_delivered_to_invited_and_code_joined_riders(self):
        provider = {'providerID': 'apple.mapkit', 'attribution': 'Apple Maps', 'storageScope': 'phoneOnly'}
        self.assertTrue(self.call('alice', 'GET', '/capabilities').json()['savedMapKitRoutes'])
        raw = self.route('private', provider=provider)
        response = self.call('alice', 'POST', '/routes', raw)
        self.assertEqual(response.status_code, 200, response.text)
        item = response.json()
        self.assertEqual(item['body']['archive'], raw['archive'])
        self.assertEqual(item['body']['sha256'], hashlib.sha256(raw['archive'].encode()).hexdigest())
        self.assertEqual(self.call('bob', 'GET', '/routes/' + item['id']).status_code, 404)
        self.friend()
        response = self.call('alice', 'POST', '/group-rides', {'routeID': item['id'], 'title': 'Saved Apple Maps ride'})
        self.assertEqual(response.status_code, 200, response.text)
        room = response.json()
        invite = self.call('alice', 'POST', '/ride-invites', {'rideID': room['id'], 'profileID': self.ids['bob']}).json()
        self.assertEqual(self.call('bob', 'GET', '/ride-invites/' + invite['id']).json()['route']['archive'], raw['archive'])
        joined = self.call('bob', 'POST', '/ride-invites/' + invite['id'] + '/accept')
        code_joined = self.call('carol', 'POST', '/group-rides/join', {'code': room['joinCode']})
        for response in (joined, code_joined):
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()['route']['archive'], raw['archive'])
            self.assertEqual(response.json()['route']['sha256'], item['body']['sha256'])
        # Group delivery does not grant permission to republish the organizer's copy.
        response = self.call('bob', 'POST', '/routes', raw)
        self.assertEqual(response.status_code, 403, response.text)
        self.assertEqual(response.json()['code'], 'route_redistribution_not_permitted')
        self.assertEqual(self.call('bob', 'POST', '/group-rides', {'routeID': item['id'], 'title': 'Copy'}).status_code, 404)
        # Live progress uses the exact saved geometry, without recalculating a route.
        epoch = self.call('bob', 'POST', f"/group-rides/{room['id']}/consent", {'location': True, 'stats': True}).json()['epoch']
        state = {'epoch': epoch, 'sequence': 1, 'capturedAt': self.clock, 'latitude': 0, 'longitude': 0.01, 'horizontalAccuracy': 5}
        response = self.call('bob', 'POST', f"/group-rides/{room['id']}/state", state)
        self.assertEqual(response.status_code, 200, response.text)
        snapshot = self.call('alice', 'GET', '/group-rides/' + room['id']).json()
        self.assertEqual(snapshot['route']['archive'], raw['archive'])
        self.assertEqual(snapshot['riders'][0]['routeHash'], item['body']['sha256'])

    def test_saved_mapkit_policy_rejects_active_forged_and_other_provider_metadata(self):
        for provider in (
            {'providerID': 'apple.mapkit', 'attribution': 'Apple Maps', 'storageScope': 'activeOnly'},
            {'providerID': 'apple.mapkit', 'attribution': 'Apple Maps', 'storageScope': 'durable'},
            {'providerID': 'apple.mapkit', 'attribution': 'User-provided GPX', 'storageScope': 'phoneOnly'},
            {'providerID': 'strava.route', 'attribution': 'Strava', 'storageScope': 'durable'},
        ):
            with self.subTest(provider=provider):
                response = self.call('alice', 'POST', '/routes', self.route(provider=provider))
                self.assertEqual(response.status_code, 400, response.text)
                self.assertEqual(response.json()['code'], 'route_not_redistributable')

    def test_links_revoke_and_replays_do_not_resurrect(self):
        item=self.call('alice','POST','/routes',self.route('link')).json()
        link=self.call('alice','POST','/share-links',{'contentID':item['id']},key='share-create').json()
        path='/shared/'+link['url'].split('#')[-1]
        self.assertEqual(self.client.post('/shared/resolve', json={'code':link['url'].split('#')[-1]}).status_code,200)
        self.call('alice','PATCH','/routes/'+item['id'],{'revision':1,'title':'Ride','visibility':'private'})
        self.assertEqual(self.client.post('/shared/resolve', json={'code':link['url'].split('#')[-1]}).status_code,404)
        self.assertEqual(self.call('alice','POST','/share-links',{'contentID':item['id']},key='share-create').status_code,404)
    def test_live_consent_epoch_replay_age_and_block(self):
        room=self.ride();rid=room['id']
        epoch=self.call('bob','POST',f'/group-rides/{rid}/consent',{'location':True,'stats':False}).json()['epoch']
        state={'epoch':epoch,'sequence':1,'capturedAt':self.clock,'latitude':0,'longitude':0.01,'horizontalAccuracy':5,'speed':10}
        self.assertEqual(self.call('bob','POST',f'/group-rides/{rid}/state',state).status_code,200)
        snapshot=self.call('alice','GET',f'/group-rides/{rid}').json()
        self.assertEqual(len(snapshot['riders']),1);self.assertNotIn('speed',snapshot['riders'][0])
        self.assertEqual(self.call('bob','POST',f'/group-rides/{rid}/state',state).status_code,409)
        self.clock+=61
        self.assertEqual(self.call('alice','GET',f'/group-rides/{rid}').json()['riders'],[])
        self.call('bob','POST',f'/group-rides/{rid}/consent',{'location':False,'stats':False})
        state.update(sequence=2,capturedAt=self.clock)
        self.assertEqual(self.call('bob','POST',f'/group-rides/{rid}/state',state).status_code,403)
        self.call('alice','PUT',f"/blocks/{self.ids['bob']}")
        self.assertEqual(self.call('bob','GET',f'/group-rides/{rid}').status_code,404)
    def test_old_join_replay_cannot_reveal_after_block(self):
        room=self.ride()
        self.call('bob','POST','/group-rides/join',{'code':room['joinCode']},key='retry-join')
        self.call('alice','PUT',f"/blocks/{self.ids['bob']}")
        retry=self.call('bob','POST','/group-rides/join',{'code':room['joinCode']},key='retry-join')
        self.assertNotEqual(retry.status_code,200)
    def test_activity_clipping_and_privacy_change(self):
        self.friend()
        points=[{'latitude':0,'longitude':x/1000} for x in range(51)]
        body={'title':'Morning','visibility':'friends','points':points,'sourceID':'workout1','movingSeconds':600,'elapsedSeconds':700,'uploadConsent':True}
        r=self.call('alice','POST','/activities',body);self.assertEqual(r.status_code,200,r.text);item=r.json()
        for segment in item['body']['segments']:
            for p in segment:
                self.assertGreater(distance(p,points[0]),225);self.assertGreater(distance(p,points[-1]),225)
        self.assertNotIn('points',item['body']);self.assertNotIn('source',item)
        me=self.call('alice','GET','/me').json()
        edited=self.call('alice','PATCH','/me',{'version':me['version'],'username':'alice','displayName':'Alice','privacy':{'zones':[{'latitude':0,'longitude':0.02,'radius':300}]}})
        self.assertEqual(edited.status_code,200,edited.text)
        self.assertEqual(self.call('bob','GET','/activities/'+item['id']).status_code,404)
        self.assertTrue(self.call('alice','GET','/activities/'+item['id']).json()['body']['needsReprocessing'])
    def test_avatar_sanitization_version_and_authorization(self):
        image=BytesIO();Image.new('RGB',(800,500),'red').save(image,'JPEG',exif=b'Exif\x00\x00secret')
        data=image.getvalue();variants=sanitize_avatar(data)
        for name,dimension in [('profile',256),('marker',96),('hardware',40)]:
            decoded=Image.open(BytesIO(variants[name]));self.assertEqual(decoded.size,(dimension,dimension));self.assertNotIn('exif',decoded.info)
        r=self.client.put('/me/avatar?version=1',content=data,headers={'Authorization':'Bearer alice','Idempotency-Key':'picture-1'})
        self.assertEqual(r.status_code,200,r.text);asset=r.json()['avatarID']
        self.assertEqual(self.call('bob','GET',f'/media/{asset}/hardware').status_code,200)
        self.call('bob','PUT',f"/blocks/{self.ids['alice']}")
        self.assertEqual(self.call('bob','GET',f'/media/{asset}/hardware').status_code,404)
        self.call('alice','DELETE','/me/avatar')
        self.assertEqual(self.call('alice','GET',f'/media/{asset}/hardware').status_code,404)
        run_once(self.db,Identity(),self.media,Notifications(),now=self.clock)
        self.assertEqual(self.media.objects,{})
    def test_deletion_immediately_revokes_and_cleanup_retries(self):
        room=self.ride()
        result=self.call('alice','POST','/me/deletion',{'expectedProfileID':self.ids['alice']})
        self.assertEqual(result.status_code,200,result.text)
        self.assertEqual(self.call('alice','GET','/me').status_code,403)
        self.assertEqual(self.call('bob','GET','/group-rides/'+room['id']).status_code,410)
        class FailingIdentity(Identity):
            def delete(self,uid):raise RuntimeError('provider down')
        run_once(self.db,FailingIdentity(),self.media,Notifications(),now=self.clock)
        with self.db.transaction() as c:
            self.assertEqual(c.scalar(select(accounts.c.state).where(accounts.c.id==self.ids['alice'])),'deleting')
        run_once(self.db,Identity(),self.media,Notifications(),now=self.clock+100)
        with self.db.transaction() as c:
            self.assertEqual(c.scalar(select(accounts.c.state).where(accounts.c.id==self.ids['alice'])),'deleted')
    def test_serialization_failure_retries_entire_cleanup_transaction(self):
        self.call('alice','POST','/me/deletion',{'expectedProfileID':self.ids['alice']})
        attempts=[]
        class SerializationFailure(Exception):
            sqlstate='40001'
        def transient(*args):
            attempts.append(1)
            if len(attempts)==1:
                raise OperationalError('DELETE social_media', {}, SerializationFailure())
            return cleanup_account(*args)
        with patch('map_platform.social.worker.cleanup_account', side_effect=transient):
            run_once(self.db,Identity(),self.media,Notifications(),now=self.clock)
        self.assertEqual(len(attempts),2)
        with self.db.transaction() as c:
            self.assertEqual(c.scalar(select(accounts.c.state).where(accounts.c.id==self.ids['alice'])),'deleted')
            self.assertEqual(c.scalar(select(outbox.c.id)),None)
    def test_website_deletion_proof_and_replay(self):
        import hmac
        secret='x'*40
        body={'uid':'alice','project':'test','authTime':int(self.clock),'issuedAt':int(self.clock),'nonce':'00000000-0000-4000-8000-000000000001'}
        raw=json.dumps(body).encode()
        signature=hmac.new(secret.encode(),raw,'sha256').hexdigest()
        with patch.dict(os.environ,{'BICINO_SOCIAL_DELETION_SECRET':secret,'BICINO_FIREBASE_PROJECT_ID':'test'}):
            self.assertEqual(self.client.post('/internal/account-deletion',content=raw,headers={'Content-Type':'application/json'}).status_code,401)
            for _ in range(2):
                self.assertEqual(self.client.post('/internal/account-deletion',content=raw,headers={'Content-Type':'application/json','X-Bicino-Deletion-Signature':signature}).status_code,200)
            self.assertEqual(self.call('alice','GET','/me').status_code,403)
            self.clock+=61
            self.assertEqual(self.client.post('/internal/account-deletion',content=raw,headers={'Content-Type':'application/json','X-Bicino-Deletion-Signature':signature}).status_code,401)

    def test_replay_never_stores_live_coordinates(self):
        from map_platform.social.database import replays
        room=self.ride();rid=room['id']
        epoch=self.call('bob','POST',f'/group-rides/{rid}/consent',{'location':True,'stats':False}).json()['epoch']
        self.call('bob','POST',f'/group-rides/{rid}/state',{'epoch':epoch,'sequence':1,'capturedAt':self.clock,'latitude':1.2345,'longitude':2.3456,'horizontalAccuracy':5})
        self.call('alice','POST',f'/group-rides/{rid}/consent',{'location':True,'stats':False})
        with self.db.transaction() as c:
            for result in c.scalars(select(replays.c.response)):
                self.assertEqual(result.get('riders',[]),[])
        self.clock+=61
        state={'epoch':epoch,'sequence':2,'capturedAt':self.clock,'latitude':0,'longitude':0,'horizontalAccuracy':5}
        self.assertEqual(self.call('bob','POST',f'/group-rides/{rid}/state',state).status_code,200)
        self.clock += 4*3600
        state['sequence'] = 3; state['capturedAt'] = self.clock
        self.assertEqual(self.call('bob','POST',f'/group-rides/{rid}/state',state).status_code,403)

    @unittest.skipUnless(os.environ.get('BICINO_SOCIAL_TEST_DATABASE_URL'), 'requires PostgreSQL isolation')
    def test_concurrent_duplicate_request_is_one_relationship(self):
        from concurrent.futures import ThreadPoolExecutor
        from map_platform.social.database import friendships
        body={'profileID':self.ids['bob']}
        def send(index):
            with TestClient(create_app(service=self.service,identity=Identity(),features=SocialFeatures(True,True,True,True,True))) as client:
                return client.post('/friend-requests',json=body,headers={'Authorization':'Bearer alice','Idempotency-Key':'concurrent-request'}).status_code
        with ThreadPoolExecutor(max_workers=4) as executor:
            results=list(executor.map(send,range(4)))
        self.assertEqual(results,[200]*4)
        with self.db.transaction() as c:
            self.assertEqual(len(c.execute(select(friendships)).all()),1)

    def test_external_disable_restoration_requires_fresh_consent(self):
        from map_platform.social.worker import reconcile_accounts
        room = self.ride(); rid = room['id']
        self.call('bob','POST',f'/group-rides/{rid}/consent',{'location':True,'stats':False})
        class ExternalIdentity(Identity):
            state = 'disabled'
            def status(self, uid): return self.state if uid == 'bob' else 'active'
        identity = ExternalIdentity()
        reconcile_accounts(self.db, identity, self.media)
        self.assertEqual(self.call('bob','GET','/me').status_code,403)
        self.assertNotIn(self.ids['bob'], [x['id'] for x in self.call('alice','GET',f'/group-rides/{rid}').json()['members']])
        identity.state = 'active'
        reconcile_accounts(self.db, identity, self.media)
        self.assertFalse(self.call('bob','GET',f'/group-rides/{rid}').json()['sharing'])
        identity.state = 'deleted'
        reconcile_accounts(self.db, identity, self.media)
        self.assertEqual(self.call('bob','GET','/me').status_code,403)
        with self.db.transaction() as c:
            self.assertEqual(c.scalar(select(accounts.c.state).where(accounts.c.id == self.ids['bob'])), 'deleting')

    def test_owner_leave_ends_ride_and_notification_environment(self):
        room = self.ride()
        result = self.call('alice','POST',f"/group-rides/{room['id']}/leave")
        self.assertEqual(result.status_code,200,result.text)
        self.assertEqual(self.call('bob','GET',f"/group-rides/{room['id']}").status_code,410)
        result = self.call('alice','PUT','/notification-devices/'+str(uuid.uuid4()),
                           {'token':'a'*64,'environment':'production','secret':self.secret()})
        self.assertEqual(result.status_code,400,result.text)
        self.assertEqual(result.json()['code'],'notification_environment_mismatch')

    def test_lists_are_metadata_and_invitation_preview_is_recipient_only(self):
        self.friend()
        item = self.call('alice','POST','/routes',self.route()).json()
        listed = self.call('alice','GET','/routes').json()['items']
        self.assertEqual(listed[0]['body'], {})
        self.assertIn('archive', self.call('alice','GET','/routes/'+item['id']).json()['body'])
        room = self.call('alice','POST','/group-rides',{'routeID':item['id'],'title':'Saturday'}).json()
        invite = self.call('alice','POST','/ride-invites',{'rideID':room['id'],'profileID':self.ids['bob']}).json()
        self.assertNotIn('route',self.call('bob','GET','/ride-invites').json()['items'][0])
        self.assertIn('archive',self.call('bob','GET','/ride-invites/'+invite['id']).json()['route'])
        self.assertEqual(self.call('carol','GET','/ride-invites/'+invite['id']).status_code,404)
        listed_room = self.call('alice','GET','/group-rides').json()['items'][0]
        self.assertEqual(listed_room['route'],{})
        self.assertEqual(listed_room['riders'],[])

    def test_notification_category_mute_is_enforced_in_worker(self):
        from map_platform.social.database import devices
        self.device(self.ids['bob'])
        with self.db.transaction() as c:
            privacy = dict(c.scalar(select(accounts.c.privacy).where(accounts.c.id == self.ids['bob'])))
            privacy['friendNotifications'] = False
            c.execute(accounts.update().where(accounts.c.id == self.ids['bob']).values(privacy=privacy))
        self.call('alice','POST','/friend-requests',{'profileID':self.ids['bob']})
        class RecordingNotifications:
            sent = []
            def send(self, *args): self.sent.append(args); return True
        notifier = RecordingNotifications()
        run_once(self.db,Identity(),self.media,notifier,now=self.clock)
        self.assertEqual(notifier.sent,[])

    def test_group_rollout_holds_invite_push_without_blocking_deletion(self):
        from map_platform.social.database import devices
        room = self.ride()
        self.call('bob', 'POST', f"/group-rides/{room['id']}/leave")
        self.assertEqual(self.call('alice', 'POST', '/ride-invites', {'rideID': room['id'], 'profileID': self.ids['bob']}).status_code, 200)
        self.call('carol', 'POST', '/me/deletion', {'expectedProfileID': self.ids['carol']})
        self.device(self.ids['bob'])
        class RecordingNotifications:
            def __init__(self): self.sent = []
            def send(self, *args): self.sent.append(args); return True
        notifier = RecordingNotifications()
        run_once(self.db, Identity(), self.media, notifier, now=self.clock, features=SocialFeatures())
        self.assertEqual(notifier.sent, [])
        with self.db.transaction() as c:
            self.assertEqual(c.scalar(select(accounts.c.state).where(accounts.c.id == self.ids['carol'])), 'deleted')
            self.assertEqual(len(c.execute(select(outbox).where(outbox.c.kind == 'ride_invite')).all()), 1)
        run_once(self.db, Identity(), self.media, notifier, now=self.clock+61, features=SocialFeatures(routes=True, groups=True))
        self.assertEqual(len(notifier.sent), 1)

    def test_removed_member_cannot_preview_old_code_and_invites_can_be_cancelled(self):
        room = self.ride(); rid = room['id']
        self.call('alice','DELETE',f"/group-rides/{rid}/members/{self.ids['bob']}")
        self.assertEqual(self.call('bob','POST','/group-rides/preview',{'code':room['joinCode']}).status_code,403)
        invitation = self.call('alice','POST','/ride-invites',{'rideID':rid,'profileID':self.ids['bob']}).json()
        self.assertEqual(len(self.call('alice','GET','/ride-invites?sent=true').json()['items']),1)
        self.assertEqual(self.call('carol','DELETE','/ride-invites/'+invitation['id']).status_code,404)
        self.assertEqual(self.call('alice','DELETE','/ride-invites/'+invitation['id']).status_code,200)
        self.assertNotEqual(self.call('bob','POST','/ride-invites/'+invitation['id']+'/accept').status_code,200)

    def test_invalid_input_bounded(self):
        body=self.route();body['sharingRightsConfirmed']=False
        self.assertEqual(self.call('alice','POST','/routes',body).status_code,422)
        self.assertEqual(self.call('alice','POST','/group-rides/join',{'code':'a'}).status_code,422)
        with self.assertRaises((ValueError, OSError)):sanitize_avatar(b'not an image')

    def test_friends_route_cannot_be_redistributed_by_group_creator(self):
        self.friend()
        item = self.call('alice', 'POST', '/routes', self.route()).json()
        self.assertEqual(self.call('bob', 'GET', '/routes/'+item['id']).status_code, 200)
        result = self.call('bob', 'POST', '/group-rides', {'routeID':item['id'], 'title':'Copy'})
        self.assertEqual(result.status_code, 403)
        self.assertEqual(result.json()['code'], 'route_owner_required')

    def test_replay_receipts_have_no_routes_secrets_or_profile_copies(self):
        from map_platform.social.database import replays
        item = self.call('alice', 'POST', '/routes', self.route('link')).json()
        link = self.call('alice', 'POST', '/share-links', {'contentID':item['id']}, key='link-retry').json()
        room = self.call('alice', 'POST', '/group-rides', {'routeID':item['id'], 'title':'Ride'}, key='room-retry').json()
        self.call('bob', 'POST', '/group-rides/join', {'code':room['joinCode']})
        with self.db.transaction() as c:
            retained = json.dumps(list(c.scalars(select(replays.c.response))))
            self.assertNotIn(room['joinCode'], retained)
            self.assertNotIn(link['url'].split('#')[-1], retained)
            self.assertNotIn('archive', retained)
            self.assertNotIn('hashPayload', retained)
        retry = self.call('alice', 'POST', '/group-rides', {'routeID':item['id'], 'title':'Ride'}, key='room-retry')
        self.assertEqual(retry.status_code, 200)
        self.assertEqual(retry.json()['id'], room['id'])
        self.assertTrue(retry.json()['invitationCodeNeedsRotation'])
        self.assertNotIn('joinCode', retry.json())
        self.assertEqual(self.call('alice', 'POST', '/share-links', {'contentID':item['id']}, key='link-retry').json()['code'], 'fresh_link_required')
        path = '/group-rides/'+room['id']+'/rotate-code'
        first = self.call('alice', 'POST', path, key='rotate-retry').json()['joinCode']
        second = self.call('alice', 'POST', path).json()['joinCode']
        self.assertNotEqual(first, second)
        self.assertEqual(self.call('alice', 'POST', path, key='rotate-retry').json()['code'], 'fresh_invitation_required')
        self.assertEqual(self.call('bob', 'POST', '/group-rides/preview', {'code':first}).status_code, 404)

    def test_gap_hides_live_state_but_allows_resume_until_consent_deadline(self):
        room = self.ride(); path = '/group-rides/'+room['id']
        consent = self.call('bob', 'POST', path+'/consent', {'location':True,'stats':False}).json()
        state = {'epoch':consent['epoch'],'sequence':1,'capturedAt':self.clock,'latitude':0,'longitude':0,'horizontalAccuracy':5}
        self.assertEqual(self.call('bob', 'POST', path+'/state', state).status_code, 200)
        self.assertNotIn('epoch', self.call('alice','GET',path).json()['riders'][0])
        self.clock += 61
        run_once(self.db, Identity(), self.media, Notifications(), now=self.clock)
        snapshot = self.call('bob','GET',path).json()
        self.assertTrue(snapshot['sharing']); self.assertEqual(snapshot['riders'], [])
        state.update(sequence=2,capturedAt=self.clock)
        self.assertEqual(self.call('bob','POST',path+'/state',state).status_code,200)
        self.clock = consent['sharingExpiresAt']+1
        state.update(sequence=3,capturedAt=self.clock)
        self.assertEqual(self.call('bob','POST',path+'/state',state).status_code,403)

    def test_worker_does_not_rewrite_cleared_history(self):
        from sqlalchemy import event
        room = self.ride()
        self.clock += 86401
        run_once(self.db, Identity(), self.media, Notifications(), now=self.clock)
        writes = []
        def record(c, cursor, statement, parameters, context, many):
            if statement.startswith('UPDATE social_'): writes.append(cursor.rowcount)
        event.listen(self.db.engine, 'after_cursor_execute', record)
        try: run_once(self.db, Identity(), self.media, Notifications(), now=self.clock+10)
        finally: event.remove(self.db.engine, 'after_cursor_execute', record)
        self.assertEqual(sum(writes), 0)

    def test_identity_reconciliation_is_project_scoped_and_mass_delete_stops(self):
        from map_platform.social.worker import reconcile_accounts
        from sqlalchemy import update
        class Wrong(Identity):
            project = 'wrong-project'
            def status(self, uid): raise AssertionError('must not query another project')
        reconcile_accounts(self.db, Wrong(), self.media)
        self.service.account(AccountPrincipal('test','fourth',int(self.clock)))
        class Missing(Identity):
            def status(self, uid): return 'deleted'
        with self.assertLogs(level='ERROR'):
            reconcile_accounts(self.db, Missing(), self.media)
        with self.db.transaction() as c:
            self.assertEqual(set(c.scalars(select(accounts.c.state))), {'active'})
            self.assertEqual(list(c.scalars(select(outbox.c.kind))), [])

    def test_held_reconciliation_batch_has_a_reviewed_operator_recovery_and_then_resumes(self):
        from map_platform.social.worker import (ReconciliationRefused, reconcile_accounts,
                                                resolve_reconciliation, review_reconciliation, _parser)
        for index in range(9):
            self.service.account(AccountPrincipal('test', f'extra{index}', int(self.clock)))
        other = self.service.account(AccountPrincipal('other-project', 'outsider', int(self.clock)))
        with self.db.transaction() as c:
            uids = dict(c.execute(select(accounts.c.id, accounts.c.uid).where(accounts.c.project == 'test')).all())
        ordered = sorted(uids)
        self.assertEqual(len(ordered), 12)
        deleted, disabled_late = set(ordered[:4]), ordered[11]
        class External(Identity):
            calls = []
            def status(self, uid):
                self.calls.append(uid)
                if uid == 'outsider': raise AssertionError('must not query another project')
                account = next(key for key, value in uids.items() if value == uid)
                if account in deleted: return 'deleted'
                return 'disabled' if account == disabled_late else 'active'
        identity = External()
        def states():
            with self.db.transaction() as c:
                return dict(c.execute(select(accounts.c.id, accounts.c.state)).all())
        before = states()
        # Four external deletions in one batch trip the breaker on every pass.
        for _ in range(2):
            with self.assertLogs(level='ERROR'):
                self.assertEqual(reconcile_accounts(self.db, identity, self.media, '', batch_size=6), '')
        self.assertEqual(states(), before)
        # Review is read-only and names internal account IDs of the held batch.
        report = review_reconciliation(self.db, identity, '', batch_size=6)
        self.assertEqual(report, {'held': True, 'cursor': '', 'deleted': sorted(deleted), 'checked': 6, 'batch': 6})
        self.assertEqual(states(), before)
        for refused in ([ordered[0], ordered[0]],            # duplicates
                        sorted(deleted)[:3],                  # an unreviewed deletion remains
                        sorted(deleted) + [ordered[4]],       # not deleted at the provider
                        sorted(deleted) + [ordered[8]],       # outside the held batch
                        sorted(deleted) + [other]):           # another project
            with self.assertRaises(ReconciliationRefused):
                resolve_reconciliation(self.db, identity, self.media, '', refused, confirm=True, batch_size=6)
        self.assertEqual(states(), before)
        dry = resolve_reconciliation(self.db, identity, self.media, '', sorted(deleted), batch_size=6)
        self.assertEqual(dry, {'applied': False, 'cursor': '', 'reviewed': 4})
        self.assertEqual(states(), before)
        # Operator confirmation applies exactly the reviewed batch.
        applied = resolve_reconciliation(self.db, identity, self.media, '', sorted(deleted), confirm=True, batch_size=6)
        self.assertTrue(applied['applied'])
        after = states()
        self.assertEqual({key for key, value in after.items() if value == 'deleting'}, deleted)
        self.assertEqual(after[other], 'active')
        with self.db.transaction() as c:
            self.assertEqual(sorted(c.scalars(select(outbox.c.owner).where(outbox.c.kind == 'delete_account'))), sorted(deleted))
        # The worker's next passes make progress through later batches again.
        cursor = applied['cursor']
        for _ in range(3):
            cursor = reconcile_accounts(self.db, identity, self.media, cursor, batch_size=6)
            if not cursor: break
        self.assertEqual(states()[disabled_late], 'disabled')
        self.assertEqual(review_reconciliation(self.db, identity, '', batch_size=6), {'held': False, 'complete': True})
        self.assertNotIn('outsider', identity.calls)
        # The CLI requires an explicit cursor and reviewed accounts; confirmation is opt-in.
        parsed = _parser().parse_args(['reconcile-resolve', '--cursor', '', '--account', ordered[0]])
        self.assertFalse(parsed.confirm)
        import contextlib, io
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            _parser().parse_args(['reconcile-resolve', '--account', ordered[0]])
        self.assertEqual(_parser().parse_args(['worker']).command, 'worker')

    def test_reconciliation_resolution_cannot_add_an_unreviewed_provider_deletion(self):
        from collections import Counter
        from map_platform.social.worker import resolve_reconciliation
        for index in range(3):
            self.service.account(AccountPrincipal('test', f'snapshot{index}', int(self.clock)))
        with self.db.transaction() as c:
            batch = list(c.execute(select(accounts).order_by(accounts.c.id)).mappings())
        reviewed = {account['id'] for account in batch[:4]}
        deleted_uids = {account['uid'] for account in batch[:4]}
        unreviewed = batch[4]
        calls = Counter()
        class Changing(Identity):
            def status(self, uid):
                calls[uid] += 1
                if uid in deleted_uids:
                    return 'deleted'
                # A second lookup sees a deletion the operator never reviewed.
                if uid == unreviewed['uid'] and calls[uid] > 1:
                    return 'deleted'
                return 'active'
        result = resolve_reconciliation(self.db, Changing(), self.media, '', sorted(reviewed),
                                        confirm=True, batch_size=6)
        self.assertTrue(result['applied'])
        with self.db.transaction() as c:
            states = dict(c.execute(select(accounts.c.id, accounts.c.state)).all())
            self.assertEqual({key for key, state in states.items() if state == 'deleting'}, reviewed)
            self.assertEqual(states[unreviewed['id']], 'active')
            self.assertEqual(set(c.scalars(select(outbox.c.owner).where(outbox.c.kind == 'delete_account'))), reviewed)
        self.assertEqual(set(calls.values()), {1})

    def test_reconciliation_resolution_refuses_an_incomplete_provider_snapshot(self):
        from map_platform.social.worker import ReconciliationRefused, resolve_reconciliation
        with self.db.transaction() as c:
            batch = list(c.execute(select(accounts).order_by(accounts.c.id)).mappings())
        reviewed, unavailable = batch[0], batch[1]
        class Outage(Identity):
            def status(self, uid):
                if uid == reviewed['uid']:
                    return 'deleted'
                if uid == unavailable['uid']:
                    raise RuntimeError('provider unavailable')
                return 'active'
        for confirm in (False, True):
            with self.assertRaises(ReconciliationRefused):
                resolve_reconciliation(self.db, Outage(), self.media, '', [reviewed['id']],
                                       confirm=confirm, batch_size=3)
            with self.db.transaction() as c:
                self.assertEqual(set(c.scalars(select(accounts.c.state))), {'active'})
                self.assertEqual(list(c.scalars(select(outbox.c.kind))), [])

    def test_disabled_sender_is_skipped_and_invitations_are_revoked(self):
        from map_platform.social.database import invites
        from map_platform.social.worker import reconcile_accounts
        from sqlalchemy import update
        room = self.ride()
        self.call('bob','POST',f"/group-rides/{room['id']}/leave")
        self.assertEqual(self.call('alice','POST','/ride-invites',{'rideID':room['id'],'profileID':self.ids['bob']}).status_code,200)
        with self.db.transaction() as c:
            c.execute(update(accounts).where(accounts.c.id==self.ids['alice']).values(state='disabled'))
        response = self.call('bob','GET','/ride-invites')
        self.assertEqual(response.status_code,200); self.assertEqual(response.json()['items'],[])
        class Disabled(Identity):
            def status(self, uid): return 'disabled' if uid=='alice' else 'active'
        reconcile_accounts(self.db,Disabled(),self.media)
        with self.db.transaction() as c:
            self.assertEqual(set(c.scalars(select(invites.c.status))),{'revoked'})

    def test_declined_request_cannot_be_resent_by_original_sender(self):
        request = self.call('alice','POST','/friend-requests',{'profileID':self.ids['bob']}).json()
        self.call('bob','POST','/friend-requests/'+request['id']+'/decline')
        self.assertEqual(self.call('alice','POST','/friend-requests',{'profileID':self.ids['bob']}).json()['code'],'request_declined')
        for mode in ('remove', 'block-unblock'):
            if mode == 'remove':
                self.call('alice','DELETE','/friends/'+self.ids['bob'])
            else:
                self.call('alice','PUT','/blocks/'+self.ids['bob'])
                self.call('alice','DELETE','/blocks/'+self.ids['bob'])
            self.clock += 86401
            self.assertEqual(self.call('alice','POST','/friend-requests',{'profileID':self.ids['bob']}).json()['code'],'request_declined')
        # The recipient can still initiate a new relationship voluntarily.
        self.assertEqual(self.call('bob','POST','/friend-requests',{'profileID':self.ids['alice']}).status_code,200)

    def test_malformed_consent_is_422_even_when_features_are_off(self):
        self.client.app.state.features = SocialFeatures()
        response = self.client.post('/group-rides/anything/consent',content=b'{bad',headers={'Authorization':'Bearer alice','Content-Type':'application/json'})
        self.assertEqual(response.status_code,422)

    def test_deletion_retry_and_deleted_identity_cannot_recreate_account(self):
        self.assertEqual(self.call('alice','POST','/me/deletion',{'expectedProfileID':self.ids['alice']}).status_code,200)
        self.assertEqual(self.call('alice','POST','/me/deletion',{'expectedProfileID':self.ids['alice']}).json()['code'],'account_deleting')
        run_once(self.db,Identity(),self.media,Notifications(),now=self.clock)
        self.assertEqual(self.call('alice','GET','/me').status_code,403)
        self.assertEqual(self.call('alice','POST','/me/deletion',{'expectedProfileID':self.ids['alice']}).json()['code'],'account_deleted')
        with self.db.transaction() as c:
            self.assertEqual(len(list(c.scalars(select(accounts.c.id)))),3)

    def test_media_io_is_outside_database_transaction_and_revalidates(self):
        from sqlalchemy import event, update
        active = set()
        event.listen(self.db.engine,'begin',lambda c:active.add(id(c)))
        event.listen(self.db.engine,'commit',lambda c:active.discard(id(c)))
        event.listen(self.db.engine,'rollback',lambda c:active.discard(id(c)))
        original_put,original_get = self.media.put,self.media.get
        def put(key, value):
            self.assertFalse(active); original_put(key,value)
        def get(key):
            self.assertFalse(active)
            with self.db.transaction() as c:
                c.execute(update(accounts).where(accounts.c.id==self.ids['alice']).values(avatar=None))
            return original_get(key)
        self.media.put=put; self.media.get=get
        image=BytesIO(); Image.new('RGB',(80,80)).save(image,format='PNG')
        response=self.client.put('/me/avatar?version=1',content=image.getvalue(),headers={'Authorization':'Bearer alice','Idempotency-Key':'photo-io'})
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(self.call('alice','GET','/media/'+response.json()['avatarID']+'/marker').status_code,404)

    def test_activity_private_reupload_revokes_prior_links(self):
        data={'uploadConsent':True,'sourceID':'track-1','title':'Track','visibility':'link','elapsedSeconds':100,'movingSeconds':80,
              'points':[{'latitude':10,'longitude':20},{'latitude':10.01,'longitude':20.01}]}
        item=self.call('alice','POST','/activities',data)
        self.assertEqual(item.status_code,200,item.text)
        link=self.call('alice','POST','/share-links',{'contentID':item.json()['id']}).json()
        self.assertEqual(self.client.post('/shared/resolve',json={'code':link['url'].split('#')[-1]}).status_code,200)
        data['visibility']='private';self.call('alice','POST','/activities',data)
        data['visibility']='link';self.call('alice','POST','/activities',data)
        self.assertEqual(self.client.post('/shared/resolve',json={'code':link['url'].split('#')[-1]}).status_code,404)

    def test_schema_upgrade_retires_unsafe_replays_and_json_null_live(self):
        from sqlalchemy import JSON, update
        from map_platform.social.database import replays, versions
        self.ride()
        with self.db.transaction() as c:
            c.execute(update(versions).values(version=1))
            c.execute(update(members).values(live=JSON.NULL))
            c.execute(replays.insert().values(owner=self.ids['alice'],key='legacy-secret',digest='0'*64,response={'joinCode':'legacy-secret','route':{'archive':'private'}},created=self.clock))
        self.db.migrate();self.db.check_schema()
        with self.db.transaction() as c:
            self.assertEqual(list(c.scalars(select(replays.c.response))),[])
            self.assertEqual(len(list(c.scalars(select(members.c.account).where(members.c.live.is_not(None))))),0)

    def test_consent_epoch_rejects_delayed_start_and_stop_and_supports_rollback(self):
        room=self.ride();path='/group-rides/'+room['id']
        old=self.call('bob','GET',path+'/consent').json()['epoch']
        active=self.call('bob','POST',path+'/consent',{'epoch':old,'location':True,'stats':False}).json()
        self.assertEqual(self.call('bob','POST',path+'/consent',{'epoch':old,'location':False,'stats':False}).json()['code'],'consent_changed')
        self.client.app.state.features=SocialFeatures(routes=True)
        current=self.call('bob','GET',path+'/consent')
        self.assertEqual(current.status_code,200)
        self.assertNotIn('route',current.json())
        stopped=self.call('bob','POST',path+'/consent',{'epoch':current.json()['epoch'],'location':False,'stats':False})
        self.assertEqual(stopped.status_code,200,stopped.text);self.assertFalse(stopped.json()['sharing'])
        self.client.app.state.features=SocialFeatures(True,True,True,True,True)
        self.assertEqual(self.call('bob','POST',path+'/consent',{'epoch':old,'location':True,'stats':False}).status_code,409)
        state={'epoch':active['epoch'],'sequence':1,'capturedAt':self.clock,'latitude':0,'longitude':0,'horizontalAccuracy':5}
        self.assertEqual(self.call('bob','POST',path+'/state',state).status_code,403)

    def test_push_binding_length_matches_database_limit(self):
        body={'token':'a'*64,'environment':'development','secret':self.secret()}
        for installation in ['a'*37, 'b'*36, 'not-a-uuid']:
            response=self.call('alice','PUT','/notification-devices/'+installation,body)
            self.assertEqual(response.status_code,400,installation)
            self.assertEqual(response.json()['code'],'invalid_binding')

    def test_cleanup_checks_project_before_any_firebase_mutation(self):
        class Wrong(Identity):
            project='other-project'
            def delete(self,uid):raise AssertionError('must not contact another project')
        with self.assertRaisesRegex(ValueError,'Firebase project mismatch'):
            self.db.run(lambda c:cleanup_account(c,self.ids['alice'],Wrong(),self.media))

    def test_website_deletion_clock_window_matches_native_and_web(self):
        import hmac,uuid
        secret='s'*40
        with patch.dict(os.environ,{'BICINO_SOCIAL_DELETION_SECRET':secret,'BICINO_FIREBASE_PROJECT_ID':'test'}):
            for age in [-61,-60,0,300,301]:
                proof={'uid':'absent-account','project':'test','authTime':int(self.clock-age),
                       'issuedAt':int(self.clock),'nonce':str(uuid.uuid4())}
                raw=json.dumps(proof).encode();signature=hmac.new(secret.encode(),raw,'sha256').hexdigest()
                response=self.client.post('/internal/account-deletion',content=raw,
                    headers={'Content-Type':'application/json','X-Bicino-Deletion-Signature':signature})
                self.assertEqual(response.status_code,200 if -60<=age<=300 else 401)
                if not -60<=age<=300:
                    self.assertEqual(response.json(),{'code':'reauthentication_required'})

    def website_proof(self, secret, uid='alice', project='test', auth_age=0, issued_age=0, signature=None):
        import hmac
        proof={'uid':uid,'project':project,'authTime':int(self.clock-auth_age),
               'issuedAt':int(self.clock-issued_age),'nonce':str(uuid.uuid4())}
        raw=json.dumps(proof).encode()
        signed=signature if signature is not None else hmac.new(secret.encode(),raw,'sha256').hexdigest()
        return self.client.post('/internal/account-deletion',content=raw,
            headers={'Content-Type':'application/json','X-Bicino-Deletion-Signature':signed})

    def limiter_rows(self):
        from map_platform.social.database import limits
        with self.db.transaction() as c:
            return sorted(c.scalars(select(limits.c.key)))

    def test_website_deletion_errors_are_typed_in_validation_order(self):
        secret='w'*40
        with patch.dict(os.environ,{'BICINO_SOCIAL_DELETION_SECRET':'short','BICINO_FIREBASE_PROJECT_ID':'test'}):
            response=self.website_proof('short')
            self.assertEqual((response.status_code,response.json()),(503,{'code':'deletion_bridge_unconfigured'}))
        with patch.dict(os.environ,{'BICINO_SOCIAL_DELETION_SECRET':secret,'BICINO_FIREBASE_PROJECT_ID':'test'}):
            rows=self.limiter_rows()
            # The signature is checked first, even when every other field is also wrong,
            # and an unsigned request touches no database state.
            for response in (self.website_proof(secret,signature='0'*64),
                             self.website_proof(secret,project='other',auth_age=900,issued_age=900,signature='0'*64)):
                self.assertEqual((response.status_code,response.json()),(401,{'code':'deletion_proof_invalid'}))
            self.assertEqual(self.limiter_rows(),rows)
            response=self.website_proof(secret,project='other',auth_age=900,issued_age=900)
            self.assertEqual((response.status_code,response.json()),(403,{'code':'deletion_project_mismatch'}))
            response=self.website_proof(secret,auth_age=900,issued_age=61)
            self.assertEqual((response.status_code,response.json()),(401,{'code':'deletion_proof_expired'}))
            response=self.website_proof(secret,auth_age=301)
            self.assertEqual((response.status_code,response.json()),(401,{'code':'reauthentication_required'}))
            self.assertEqual(self.limiter_rows(),rows)
            self.assertEqual(self.call('alice','GET','/me').status_code,200)
            response=self.website_proof(secret)
            self.assertEqual((response.status_code,response.json()),(200,{'status':'deleting'}))
            self.assertEqual(self.call('alice','GET','/me').status_code,403)

    def test_verified_website_proofs_are_bounded_per_account_subject(self):
        import map_platform.social.api as social_api
        secret='v'*40
        with patch.dict(os.environ,{'BICINO_SOCIAL_DELETION_SECRET':secret,'BICINO_FIREBASE_PROJECT_ID':'test'}), \
             patch.dict(social_api.ANONYMOUS_LIMITS,{'website_deletion':2}):
            statuses=[self.website_proof(secret,uid='absent-subject').status_code for _ in range(3)]
            self.assertEqual(statuses,[200,200,429])
            self.assertEqual(self.website_proof(secret,uid='bob').status_code,200)  # another subject
            self.clock+=3600
            self.assertEqual(self.website_proof(secret,uid='absent-subject').status_code,200)

    # F1: route redistribution follows what Bicino actually handed to a rider.
    def test_received_routes_cannot_be_republished_after_save_duplicate_or_reverse(self):
        self.friend()
        points=[(0,0),(0,0.01),(0.01,0.02),(0.02,0.02)]
        original=self.call('alice','POST','/routes',self.route_body(points,'00000000-0000-4000-8000-000000000101')).json()
        # Carol never received it: identical geometry from an independent GPX file is hers to publish.
        self.assertEqual(self.call('carol','POST','/routes',self.route_body(points,'00000000-0000-4000-8000-000000000102','private')).status_code,200)
        self.assertEqual(self.call('bob','GET','/routes/'+original['id']).status_code,200)
        self.assertNotIn('fingerprint',self.call('bob','GET','/routes/'+original['id']).json())
        copies=[self.route_body(points,'00000000-0000-4000-8000-000000000101','link'),            # exact saved copy
                self.route_body(points,'00000000-0000-4000-8000-000000000103','friends'),         # duplicate with a new route ID
                self.route_body(list(reversed(points)),'00000000-0000-4000-8000-000000000104','private')]  # reversed copy
        for copy in copies:
            response=self.call('bob','POST','/routes',copy)
            self.assertEqual(response.status_code,403,response.text)
            self.assertEqual(response.json()['code'],'route_redistribution_not_permitted')
        # The restriction survives the friendship and the source route.
        self.call('alice','DELETE','/friends/'+self.ids['bob'])
        self.call('alice','DELETE','/routes/'+original['id'])
        self.assertEqual(self.call('bob','POST','/routes',copies[1]).status_code,403)
        # Bob's own different route and Alice's own geometry stay publishable.
        self.assertEqual(self.call('bob','POST','/routes',self.route_body([(1,1),(1,1.01)],'00000000-0000-4000-8000-000000000105')).status_code,200)
        self.assertEqual(self.call('alice','POST','/routes',self.route_body(points,'00000000-0000-4000-8000-000000000106','link')).status_code,200)

    def test_group_snapshots_previews_and_links_restrict_republication(self):
        points=[(0,1),(0.01,1),(0.02,1.01)]
        source=self.call('alice','POST','/routes',self.route_body(points,'00000000-0000-4000-8000-000000000111','link')).json()
        room=self.call('alice','POST','/group-rides',{'routeID':source['id'],'title':'Saturday'}).json()
        self.assertEqual(self.call('carol','POST','/group-rides/preview',{'code':room['joinCode']}).status_code,200)
        self.assertEqual(self.call('bob','POST','/group-rides/join',{'code':room['joinCode']}).status_code,200)
        for who,route_id in [('carol','00000000-0000-4000-8000-000000000112'),('bob','00000000-0000-4000-8000-000000000113')]:
            self.assertEqual(self.call(who,'POST','/routes',self.route_body(points,route_id,'private')).json()['code'],
                             'route_redistribution_not_permitted')
        # An authenticated link resolution records receipt too; the owner is never restricted.
        link=self.call('alice','POST','/share-links',{'contentID':source['id']}).json()
        other=[(2,2),(2.01,2)]
        mine=self.call('alice','POST','/routes',self.route_body(other,'00000000-0000-4000-8000-000000000114','link')).json()
        link=self.call('alice','POST','/share-links',{'contentID':mine['id']}).json()
        self.assertEqual(self.client.post('/shared/resolve',json={'code':link['url'].split('#')[-1]},
                                          headers={'Authorization':'Bearer bob'}).status_code,200)
        self.assertEqual(self.call('bob','POST','/routes',self.route_body(other,'00000000-0000-4000-8000-000000000115')).status_code,403)
        self.assertEqual(self.call('alice','POST','/routes',self.route_body(other,'00000000-0000-4000-8000-000000000116')).status_code,200)

    # F3: an app installation proves itself with a secret only it holds.
    def bind(self, who, installation, secret, token='a'*64):
        return self.call(who,'PUT','/notification-devices/'+installation,
                         {'token':token,'environment':'development','secret':secret})
    def binding(self, installation):
        with self.db.transaction() as c:
            return c.execute(select(devices).where(devices.c.id==installation.lower())).mappings().first()
    def release(self, installation, secret, owner):
        return self.client.post(f'/notification-devices/{installation}/release',json={'secret':secret,'owner':owner})

    def test_installation_proof_hands_off_accounts_and_rejects_takeover(self):
        phone,secret=str(uuid.uuid4()).upper(),self.secret()
        self.assertEqual(self.bind('alice',phone,secret).json()['owner'],self.ids['alice'])
        # Relaunch re-binds idempotently; APNs token rotation updates the same installation.
        self.assertEqual(self.bind('alice',phone,secret,token='c'*64).status_code,200)
        self.assertEqual(self.binding(phone)['token'],'c'*64)
        # Knowing the installation ID or the push token is not proof.
        self.assertEqual(self.bind('carol',phone,self.secret(),token='c'*64).json()['code'],'notification_binding_in_use')
        self.assertEqual(self.bind('carol',str(uuid.uuid4()),self.secret(),token='c'*64).json()['code'],'notification_binding_in_use')
        for body in [(self.secret(),self.ids['alice']),(secret,self.ids['carol'])]:
            response=self.release(phone,*body)
            self.assertEqual((response.status_code,response.json()),(200,{'released':True}))
        self.assertEqual(self.binding(phone)['owner'],self.ids['alice'])
        # Alice signed out offline; Bob signs in on the same phone and the proven installation moves.
        self.assertEqual(self.bind('bob',phone,secret,token='c'*64).json()['owner'],self.ids['bob'])
        # Alice's delayed release or authenticated delete cannot remove Bob's binding.
        self.release(phone,secret,self.ids['alice'])
        self.call('alice','DELETE','/notification-devices/'+phone)
        self.assertEqual(self.binding(phone)['owner'],self.ids['bob'])
        # Pushes follow only the current owner.
        self.call('alice','POST','/friend-requests',{'profileID':self.ids['bob']})
        self.call('bob','POST','/friend-requests',{'profileID':self.ids['carol']})
        self.call('carol','POST','/friend-requests',{'profileID':self.ids['alice']})
        class Recording:
            def __init__(self): self.sent=[]
            def send(self, binding, kind, event): self.sent.append(binding['owner']); return True
        notifier=Recording()
        run_once(self.db,Identity(),self.media,notifier,now=self.clock)
        self.assertEqual(notifier.sent,[self.ids['bob']])
        # Bob's forced sign-out cleanup needs no bearer token, only the installation secret.
        self.assertEqual(self.release(phone,secret,self.ids['bob']).status_code,200)
        self.assertIsNone(self.binding(phone))
        # The same account may move its own token to a reinstalled installation.
        self.bind('bob',phone,secret,token='d'*64)
        reinstall=str(uuid.uuid4())
        self.assertEqual(self.bind('bob',reinstall,self.secret(),token='d'*64).status_code,200)
        self.assertIsNone(self.binding(phone))
        self.assertEqual(self.binding(reinstall)['owner'],self.ids['bob'])
        # Malformed proofs are rejected before any lookup.
        self.assertEqual(self.client.post(f'/notification-devices/{phone}/release',json={'secret':'short','owner':self.ids['bob']}).status_code,422)

    # F5: an accepted deletion can be confirmed with its receipt secret alone.
    def test_deletion_receipt_confirms_only_an_accepted_deletion(self):
        resolve=lambda secret: self.client.post('/deletion-receipts/resolve',json={'receipt':secret})
        self.assertEqual(resolve(self.secret()).json()['code'],'unknown_receipt')
        rejected=self.secret()
        response=self.call('bob','POST','/me/deletion',{'expectedProfileID':self.ids['alice'],
                           'receiptDigest':hashlib.sha256(rejected.encode()).hexdigest()})
        self.assertEqual(response.status_code,409)
        self.assertEqual(resolve(rejected).status_code,404)
        self.assertEqual(self.client.post('/me/deletion',json={'expectedProfileID':self.ids['bob']},
            headers={'Authorization':'Bearer bob','Idempotency-Key':'missing-receipt'}).status_code,422)
        self.assertEqual(self.call('alice','POST','/me/deletion',{'expectedProfileID':self.ids['alice']}).status_code,200)
        receipt=self.deletionReceipts['alice']
        self.assertEqual(resolve(receipt).json(),{'status':'deleting','profileID':self.ids['alice']})
        run_once(self.db,Identity(),self.media,Notifications(),now=self.clock)
        self.assertEqual(resolve(receipt).json(),{'status':'deleted','profileID':self.ids['alice']})
        # Receipts outlive identity cleanup, then expire after their retention period.
        run_once(self.db,Identity(),self.media,Notifications(),now=self.clock+31*86400)
        self.assertEqual(resolve(receipt).status_code,404)

    # F6: invitations cannot be used to re-alert a recipient.
    def test_invitations_respect_decline_membership_and_alert_limits(self):
        self.friend()
        route=self.call('alice','POST','/routes',self.route()).json()
        # Scheduled ahead so the one-day alert interval elapses within the room's lifetime.
        room=self.call('alice','POST','/group-rides',{'routeID':route['id'],'title':'Saturday',
                       'startsAt':self.clock+3*86400}).json()
        invite=lambda: self.call('alice','POST','/ride-invites',{'rideID':room['id'],'profileID':self.ids['bob']})
        def alerts():
            with self.db.transaction() as c:
                return len(c.execute(select(outbox).where(outbox.c.kind=='ride_invite')).all())
        first=invite().json()
        self.assertEqual((first['status'],alerts()),('pending',1))
        self.assertEqual((invite().json()['id'],alerts()),(first['id'],1))
        self.call('alice','DELETE','/ride-invites/'+first['id'])
        reissued=invite().json()
        self.assertNotEqual(reissued['id'],first['id'])
        self.assertEqual((reissued['status'],alerts()),('pending',1))
        self.clock+=86401
        self.call('alice','DELETE','/ride-invites/'+reissued['id'])
        reissued=invite().json()
        self.assertEqual(alerts(),2)
        self.assertEqual(self.call('bob','POST',f"/ride-invites/{reissued['id']}/decline").status_code,200)
        for _ in range(3):
            response=invite()
            self.assertEqual((response.status_code,response.json()['code']),(409,'invitation_declined'))
        self.assertEqual(alerts(),2)
        with self.db.transaction() as c:
            self.assertEqual(c.scalar(select(invites.c.status).where(invites.c.recipient==self.ids['bob'])),'declined')
        # The recipient may still join voluntarily; members cannot be re-alerted.
        self.assertEqual(self.call('bob','POST','/group-rides/join',{'code':room['joinCode']}).status_code,200)
        response=invite()
        self.assertEqual((response.status_code,response.json()['code'],alerts()),(409,'already_member',2))

    def test_joining_by_code_settles_a_pending_invitation(self):
        self.friend()
        route=self.call('alice','POST','/routes',self.route()).json()
        room=self.call('alice','POST','/group-rides',{'routeID':route['id'],'title':'Saturday'}).json()
        self.call('alice','POST','/ride-invites',{'rideID':room['id'],'profileID':self.ids['bob']})
        self.assertEqual(len(self.call('bob','GET','/ride-invites').json()['items']),1)
        self.call('bob','POST','/group-rides/join',{'code':room['joinCode']})
        self.assertEqual(self.call('bob','GET','/ride-invites').json()['items'],[])

    # N2: read transactions retry conflicts without replaying mutations.
    def test_read_handlers_retry_conflicts_report_exhaustion_and_keep_real_faults(self):
        room=self.ride()
        class Conflict(Exception): sqlstate='40001'
        class Deadlock(Exception): sqlstate='40P01'
        class Missing(Exception): sqlstate='42P01'
        calls=[]
        def flaky(original, failures, error):
            def wrapper(*args, **kwargs):
                calls.append(1)
                if len(calls)<=failures:
                    raise OperationalError('SELECT', {}, error())
                return original(*args, **kwargs)
            return wrapper
        with patch.object(self.service,'ride_read',flaky(self.service.ride_read,2,Conflict)):
            response=self.call('bob','GET','/group-rides/'+room['id'])
        self.assertEqual((response.status_code,len(calls)),(200,3))
        calls.clear()
        with patch.object(self.service,'ride_read',flaky(self.service.ride_read,99,Deadlock)):
            response=self.call('bob','GET','/group-rides/'+room['id'])
        self.assertEqual((response.status_code,response.json()['code'],len(calls)),(503,'database_busy',5))
        calls.clear()
        with patch.object(self.service,'ride_read',flaky(self.service.ride_read,99,Missing)):
            with self.assertRaises(OperationalError):
                self.call('bob','GET','/group-rides/'+room['id'])
        self.assertEqual(len(calls),1)
        # A read-only POST preview retries its read, while its rate charge happens once.
        from map_platform.social.database import limits
        def charges():
            with self.db.transaction() as c:
                return c.scalar(select(limits.c.count).where(limits.c.key==self.ids['carol']+':join')) or 0
        before=charges(); calls.clear()
        with patch.object(self.service,'expose',flaky(self.service.expose,2,Conflict)):
            response=self.call('carol','POST','/group-rides/preview',{'code':room['joinCode']})
        self.assertEqual((response.status_code,len(calls),charges()-before),(200,3,1))

    # N3: decompression-bomb dimensions are invalid input, rejected from the header.
    def test_avatar_dimension_bombs_are_invalid_images_without_decoding(self):
        import struct, tracemalloc, zlib
        def png_header(width, height):
            def chunk(kind, data):
                return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
            return (b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))
                    +chunk(b'IDAT',zlib.compress(b''))+chunk(b'IEND',b''))
        for width,height in [(10000,10000),(20000,20000)]:  # warning tier and error tier
            data=png_header(width,height)
            tracemalloc.start()
            try:
                with self.assertRaises(ValueError): sanitize_avatar(data)
                _,peak=tracemalloc.get_traced_memory()
            finally:
                tracemalloc.stop()
            self.assertLess(peak,2*1024*1024)
            response=self.client.put('/me/avatar?version=1',content=data,
                headers={'Authorization':'Bearer alice','Idempotency-Key':f'bomb-{width}'})
            self.assertEqual((response.status_code,response.json()['code']),(400,'invalid_image'))

    # N4: rate accounting is a database transaction and must never run on the event loop.
    def test_rate_accounting_runs_off_the_event_loop(self):
        import asyncio
        room=self.ride()
        observed=[]
        original=self.service.rate
        def rate(actor, category, *args):
            try:
                asyncio.get_running_loop(); on_loop=True
            except RuntimeError:
                on_loop=False
            observed.append((category,on_loop))
            return original(actor,category,*args)
        with patch.object(self.service,'rate',rate):
            with self.client.websocket_connect(f"/group-rides/{room['id']}/live",headers={'Authorization':'Bearer bob'}) as socket:
                socket.receive_json()
            self.call('alice','POST','/friend-requests',{'profileID':self.ids['carol']})
            self.call('alice','POST','/routes',self.route())
            self.call('bob','POST',f"/group-rides/{room['id']}/messages",{'status':'waiting'})
            self.client.put('/me/avatar?version=1',content=b'not an image',headers={'Authorization':'Bearer alice','Idempotency-Key':'off-loop'})
        categories={category for category,_ in observed}
        self.assertTrue({'sockets','friend_requests','publication','messages','avatar','requests'}<=categories,categories)
        self.assertEqual([entry for entry in observed if entry[1]],[])

    # F2: a provider outage is reported as temporarily unavailable, never as revocation.
    def test_identity_outage_is_503_and_socket_retry_later(self):
        from map_platform.user_auth import IdentityUnavailable
        class Outage(Identity):
            def verify(self, token):
                if token=='outage': raise IdentityUnavailable('provider')
                return super().verify(token)
        client=TestClient(create_app(service=self.service,identity=Outage(),features=SocialFeatures(True,True,True,True,True)))
        try:
            response=client.get('/me',headers={'Authorization':'Bearer outage'})
            self.assertEqual((response.status_code,response.json()['code']),(503,'identity_unavailable'))
            self.assertEqual(client.get('/me',headers={'Authorization':'Bearer nobody'}).status_code,401)
            from starlette.websockets import WebSocketDisconnect
            room=self.ride()
            with client.websocket_connect(f"/group-rides/{room['id']}/live",headers={'Authorization':'Bearer outage'}) as socket:
                with self.assertRaises(WebSocketDisconnect) as closed: socket.receive_json()
            self.assertEqual(closed.exception.code,1013)
        finally:
            client.close()

    # Schema 3: an explicit migration upgrades real V2 data.
    def test_schema_v2_upgrade_retires_unproven_bindings_and_backfills_route_receipts(self):
        from sqlalchemy import Column, MetaData, Table, UniqueConstraint, inspect, update as sql_update
        from map_platform.social import database
        removed={'social_notification_devices':{'secret_digest'},'social_content':{'fingerprint'},
                 'social_rides':{'fingerprint'},'social_invites':{'notified'}}
        legacy=MetaData()
        for table in database.metadata.sorted_tables:
            if table.name in {'social_route_exposures','social_deletion_receipts'}: continue
            columns=[Column(c.name,c.type,primary_key=c.primary_key,nullable=c.nullable)
                     for c in table.columns if c.name not in removed.get(table.name,set())]
            unique=[UniqueConstraint(*[c.name for c in u.columns]) for u in table.constraints if isinstance(u,UniqueConstraint)]
            Table(table.name,legacy,*columns,*unique)
        database.metadata.drop_all(self.db.engine)
        legacy.create_all(self.db.engine)
        alice,bob,carol='a'*36,'b'*36,'c'*36
        archive=json.loads(self.route_body([(0,0),(0,0.01)],'00000000-0000-4000-8000-000000000121')['archive'])
        body={'archive':json.dumps(archive),'sha256':'0'*64,'hashPayload':'{}','distanceMeters':2000}
        with self.db.transaction() as c:
            c.execute(database.versions.insert().values(version=2))
            for account in (alice,bob,carol):
                c.execute(accounts.insert().values(id=account,project='test',uid=account,name='Rider',state='active',
                          version=1,privacy={},created=self.clock))
            c.execute(database.friendships.insert().values(id='f'*36,a=alice,b=bob,sender=alice,status='accepted',updated=self.clock))
            c.execute(content.insert().values(id='r'*36,owner=alice,kind='route',title='Loop',visibility='friends',
                      revision=1,body=body,source=None,created=self.clock))
            c.execute(database.rides.insert().values(id='g'*36,owner=alice,title='Room',route=body,status='active',
                      starts=self.clock,expires=self.clock+86400,code='d'*64,created=self.clock))
            c.execute(members.insert().values(ride='g'*36,account=carol,status='accepted',sharing=False,stats=False,
                      sequence=-1,live=None,epoch='e'*36))
            c.execute(invites.insert().values(id='i'*36,ride='g'*36,sender=alice,recipient=bob,status='pending',expires=self.clock+86400))
            c.execute(legacy.tables['social_notification_devices'].insert().values(id='p'*36,owner=bob,token='a'*64,environment='development'))
        self.db.migrate(); self.db.check_schema()
        from map_platform.social.route_archive import route_fingerprint
        fingerprint=route_fingerprint(archive['route']['points'])
        with self.db.transaction() as c:
            self.assertIn('secret_digest',{col['name'] for col in inspect(c).get_columns('social_notification_devices')})
            self.assertEqual(c.execute(select(devices)).all(),[])
            self.assertEqual(c.scalar(select(content.c.fingerprint)),fingerprint)
            self.assertEqual(c.scalar(select(database.rides.c.fingerprint)),fingerprint)
            self.assertIsNotNone(c.scalar(select(invites.c.notified)))
            self.assertEqual(set(c.execute(select(database.exposures.c.viewer,database.exposures.c.owner)).all()),
                             {(bob,alice),(carol,alice)})
            if c.dialect.name=='postgresql':
                nullable={col['name']:col['nullable'] for col in inspect(c).get_columns('social_notification_devices')}
                self.assertFalse(nullable['secret_digest'])
        self.db.migrate()  # Idempotent at the current version.
        self.db.check_schema()

    # Unauthenticated endpoints: durable per-network limits charged before any lookup.
    def anonymous_client(self, address, trusted=''):
        from map_platform.social.client_address import ClientAddressPolicy
        app=create_app(service=self.service,identity=Identity(),features=SocialFeatures(True,True,True,True,True),
                       client_addresses=ClientAddressPolicy(trusted))
        return TestClient(app,client=(address,50000))

    def shared_code(self):
        item=self.call('alice','POST','/routes',self.route('link')).json()
        return self.call('alice','POST','/share-links',{'contentID':item['id']}).json()['url'].split('#')[1]

    def test_anonymous_endpoints_are_bounded_per_network_and_recover(self):
        import map_platform.social.api as social_api
        code=self.shared_code()
        endpoints={
            'link_resolve': lambda client: client.post('/shared/resolve',json={'code':code}),
            'deletion_receipt': lambda client: client.post('/deletion-receipts/resolve',json={'receipt':self.secret()}),
            'push_release': lambda client: client.post(f'/notification-devices/{uuid.uuid4()}/release',
                                                       json={'secret':self.secret(),'owner':str(uuid.uuid4())}),
        }
        lookups=[]
        original_receipt,original_release=self.service.deletion_receipt,self.service.release_device
        def receipt(*args): lookups.append('receipt'); return original_receipt(*args)
        def release(*args): lookups.append('release'); return original_release(*args)
        with patch.dict(social_api.ANONYMOUS_LIMITS,{name:3 for name in endpoints}), \
             patch.object(self.service,'deletion_receipt',receipt), patch.object(self.service,'release_device',release):
            first,second=self.anonymous_client('203.0.113.10'),self.anonymous_client('203.0.113.11')
            for name,call in endpoints.items():
                statuses=[call(first).status_code for _ in range(4)]
                self.assertNotIn(429,statuses[:3],name)
                self.assertEqual(statuses[3],429,name)
                # The limit is charged before the endpoint's own lookup.
                before=len(lookups)
                self.assertEqual(call(first).status_code,429,name)
                self.assertEqual(len(lookups),before,name)
                # A forged forwarding header from an untrusted peer selects nothing.
                forged=first.post('/deletion-receipts/resolve',json={'receipt':self.secret()},
                                  headers={'X-Forwarded-For':'198.51.100.77'}) if name=='deletion_receipt' else None
                if forged is not None: self.assertEqual(forged.status_code,429)
                # One network cannot spend another network's allowance.
                self.assertNotEqual(call(second).status_code,429,name)
            self.assertEqual(first.post('/shared/resolve',json={'code':code}).status_code,429)
            # Signed-in resolution is charged to the account, not the exhausted network.
            signed=first.post('/shared/resolve',json={'code':code},headers={'Authorization':'Bearer bob'})
            self.assertEqual(signed.status_code,200,signed.text)
            self.clock+=3600
            for name,call in endpoints.items():
                self.assertNotEqual(call(first).status_code,429,name)
            first.close(); second.close()

    def test_signed_in_link_resolution_has_its_own_account_quota(self):
        import map_platform.social.api as social_api
        code=self.shared_code()
        with patch.object(social_api,'ACCOUNT_LINK_RESOLVE_LIMIT',2):
            client=self.anonymous_client('203.0.113.20')
            statuses=[client.post('/shared/resolve',json={'code':code},headers={'Authorization':'Bearer bob'}).status_code
                      for _ in range(3)]
            self.assertEqual(statuses,[200,200,429])
            # Another account from the same network keeps its own allowance.
            self.assertEqual(client.post('/shared/resolve',json={'code':code},headers={'Authorization':'Bearer carol'}).status_code,200)
            self.assertEqual(client.post('/shared/resolve',json={'code':code}).status_code,200)
            client.close()

    def test_forwarded_addresses_are_trusted_only_from_configured_proxies(self):
        import map_platform.social.api as social_api
        from map_platform.social.client_address import ClientAddressPolicy
        policy=ClientAddressPolicy('10.0.0.0/8, 2001:db8:ffff::/48')
        def bucket(peer, forwarded=None):
            headers=[(b'x-forwarded-for',forwarded.encode())] if forwarded is not None else []
            return policy.bucket({'client':(peer,1),'headers':headers})
        client=bucket('198.51.100.5')
        # Untrusted peers: any forwarding header is ignored.
        self.assertEqual(bucket('198.51.100.5','203.0.113.1'),client)
        # Trusted proxy: the nearest untrusted hop is the client; forged entries to its left do nothing.
        self.assertEqual(bucket('10.1.2.3','203.0.113.9, 198.51.100.5'),client)
        self.assertEqual(bucket('10.1.2.3','1.2.3.4, 198.51.100.5, 10.9.9.9'),client)
        self.assertEqual(bucket('10.1.2.3','not-an-ip, 198.51.100.5'),client)
        self.assertNotEqual(bucket('10.1.2.3','198.51.100.5, 198.51.100.6'),client)
        # A malformed nearest hop falls back to the proxy, never to a client-chosen value.
        self.assertEqual(bucket('10.1.2.3','198.51.100.5, garbage'),bucket('10.1.2.3'))
        # IPv6 clients share one bucket per /64; IPv4-mapped addresses are IPv4.
        self.assertEqual(bucket('2001:db8:1:2::1'),bucket('2001:db8:1:2:ffff::9'))
        self.assertNotEqual(bucket('2001:db8:1:2::1'),bucket('2001:db8:1:3::1'))
        self.assertEqual(bucket('::ffff:198.51.100.5'),client)
        self.assertEqual(bucket('2001:db8:ffff::1','2001:db8:1:2::7'),bucket('2001:db8:1:2::1'))
        self.assertEqual(bucket('testclient'),bucket('unix-socket'))
        with self.assertRaises(ValueError):
            ClientAddressPolicy('not-a-network')
        # End to end through a trusted proxy: clients behind it get separate buckets.
        with patch.dict(social_api.ANONYMOUS_LIMITS,{'deletion_receipt':1}):
            proxy=self.anonymous_client('10.1.2.3',trusted='10.0.0.0/8')
            def post(forwarded):
                return proxy.post('/deletion-receipts/resolve',json={'receipt':self.secret()},
                                  headers={'X-Forwarded-For':forwarded}).status_code
            self.assertEqual(post('198.51.100.5'),404)
            self.assertEqual(post('203.0.113.200, 198.51.100.5'),429)
            self.assertEqual(post('198.51.100.6'),404)
            proxy.close()

    def test_anonymous_limits_run_off_the_event_loop(self):
        import asyncio
        observed=[]
        original=self.service.anonymous_rate
        def anonymous_rate(category,*args):
            try:
                asyncio.get_running_loop(); on_loop=True
            except RuntimeError:
                on_loop=False
            observed.append((category,on_loop))
            return original(category,*args)
        code=self.shared_code()
        secret='o'*40
        with patch.object(self.service,'anonymous_rate',anonymous_rate), \
             patch.dict(os.environ,{'BICINO_SOCIAL_DELETION_SECRET':secret,'BICINO_FIREBASE_PROJECT_ID':'test'}):
            client=self.anonymous_client('203.0.113.30')
            client.post('/shared/resolve',json={'code':code})
            client.post('/deletion-receipts/resolve',json={'receipt':self.secret()})
            client.post(f'/notification-devices/{uuid.uuid4()}/release',json={'secret':self.secret(),'owner':str(uuid.uuid4())})
            client.close()
            self.website_proof(secret,uid='absent-subject')
        self.assertEqual({category for category,_ in observed},
                         {'link_resolve','deletion_receipt','push_release','website_deletion'})
        self.assertEqual([entry for entry in observed if entry[1]],[])

if __name__=='__main__':unittest.main()
