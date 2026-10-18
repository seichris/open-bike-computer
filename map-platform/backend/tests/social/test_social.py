import hashlib
import json
import unittest
import os
from io import BytesIO
from unittest.mock import patch
from PIL import Image
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.exc import OperationalError
from map_platform.social.api import create_app
from map_platform.social.features import SocialFeatures
from map_platform.social.database import Database, accounts, content, media, members, outbox
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
        self.ids={u:self.call(u,'GET','/me').json()['id'] for u in ('alice','bob','carol')}
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

    def test_disabled_sender_is_skipped_and_invitations_are_revoked(self):
        from map_platform.social.database import invites
        from map_platform.social.worker import reconcile_accounts
        from sqlalchemy import update
        room = self.ride()
        self.call('alice','POST','/ride-invites',{'rideID':room['id'],'profileID':self.ids['bob']})
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

    def test_token_binding_cannot_be_taken_by_another_account(self):
        body = {'token':'a'*64,'environment':'development'}
        self.assertEqual(self.call('alice','PUT','/notification-devices/phone-a',body).status_code,200)
        self.assertEqual(self.call('bob','PUT','/notification-devices/phone-b',body).status_code,409)
        self.assertEqual(self.call('bob','PUT','/notification-devices/phone-a',dict(body,token='b'*64)).status_code,409)
        self.call('alice','DELETE','/notification-devices/phone-a')
        self.assertEqual(self.call('bob','PUT','/notification-devices/phone-b',body).status_code,200)

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
        response=self.call('alice','PUT','/notification-devices/'+('a'*37),{'token':'a'*64,'environment':'development'})
        self.assertEqual(response.status_code,400)

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

if __name__=='__main__':unittest.main()
