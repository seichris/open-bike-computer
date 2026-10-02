import hashlib
import json
import unittest
import os
from io import BytesIO
from PIL import Image
from fastapi.testclient import TestClient
from sqlalchemy import select
from map_platform.social.api import create_app
from map_platform.social.features import SocialFeatures
from map_platform.social.database import Database, accounts, content, media, members, outbox
from map_platform.social.media import MemoryMedia, sanitize_avatar
from map_platform.social.service import SocialService
from map_platform.social.worker import run_once
from map_platform.social.geometry import distance, sanitize_track, route_progress
from map_platform.user_auth import AccountPrincipal

class Identity:
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
        self.ids={u:self.call(u,'GET','/me').json()['id'] for u in ('alice','bob','carol')}
    def tearDown(self):
        self.client.close(); self.db.engine.dispose()
    def call(self, who, method, path, body=None, key=None, **kwargs):
        self.counter+=1
        headers={'Authorization':'Bearer '+who,'Idempotency-Key':key or 'request-'+str(self.counter)}
        return self.client.request(method,path,json=body,headers=headers,**kwargs)
    def friend(self):
        r=self.call('alice','POST','/friend-requests',{'profileID':self.ids['bob']})
        self.assertEqual(r.status_code,200,r.text)
        r=self.call('bob','POST',f"/friend-requests/{r.json()['id']}/accept")
        self.assertEqual(r.status_code,200,r.text)
    def route(self, visibility='friends'):
        archive={'schemaVersion':1,'createdAt':1000000000,'route':{
            'id':'00000000-0000-4000-8000-000000000001','revision':1,
            'provider':{'providerID':'user.imported-gpx','attribution':'User-provided GPX','storageScope':'durable'},
            'localeIdentifier':'en_US','transportType':'cycling','normalizationVersion':1,
            'source':{'coordinate':{'latitude':0,'longitude':0},'label':'Start'},
            'destination':{'coordinate':{'latitude':0,'longitude':0.05},'label':'End'},
            'bounds':{'south':0,'west':0,'north':0,'east':0.05},'distanceMeters':5560,
            'points':[{'latitude':0,'longitude':0},{'latitude':0,'longitude':0.025},{'latitude':0,'longitude':0.05}],'steps':[{'id':1,'geometryStartIndex':0,'geometryEndIndex':2,'instruction':'Follow route','maneuver':'straight','distanceMeters':5560}]}}
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
        self.assertEqual(features.document(), dict(media=False, routes=False, activities=False, groups=False, hardware=False))
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
        for path in ['/routes/' + item['id'], '/activities/' + item['id'], '/shared/' + link['url'].split('/')[-1]]:
            self.assertEqual(self.call('alice', 'GET', path).status_code, 503, path)
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
    def test_links_revoke_and_replays_do_not_resurrect(self):
        item=self.call('alice','POST','/routes',self.route('link')).json()
        link=self.call('alice','POST','/share-links',{'contentID':item['id']},key='share-create').json()
        path='/shared/'+link['url'].split('/')[-1]
        self.assertEqual(self.client.get(path).status_code,200)
        self.call('alice','PATCH','/routes/'+item['id'],{'revision':1,'title':'Ride','visibility':'private'})
        self.assertEqual(self.client.get(path).status_code,404)
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
    def test_website_deletion_proof_and_replay(self):
        import hmac
        from unittest.mock import patch
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
        result = self.call('alice','PUT','/notification-devices/test',{'token':'a'*64,'environment':'production'})
        self.assertEqual(result.status_code,400,result.text)

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
        with self.db.transaction() as c:
            c.execute(devices.insert().values(id='phone', owner=self.ids['bob'], token='a'*64, environment='development'))
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
        self.call('alice', 'POST', '/ride-invites', {'rideID': room['id'], 'profileID': self.ids['bob']})
        self.call('carol', 'POST', '/me/deletion', {'expectedProfileID': self.ids['carol']})
        with self.db.transaction() as c:
            c.execute(devices.insert().values(id='phone', owner=self.ids['bob'], token='a'*64, environment='development'))
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
        self.assertEqual(self.call('bob','GET','/group-rides/preview/'+room['joinCode']).status_code,403)
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

if __name__=='__main__':unittest.main()
