import unittest
from types import SimpleNamespace
from unittest.mock import patch
import httpx
from map_platform.user_auth import AccountPrincipal, FirebaseIdentity
from map_platform.social.worker import APNs


class IdentityAndPushTest(unittest.TestCase):
    def test_recent_auth_clock_skew_and_boundary(self):
        for age in (-60, 0, 300): AccountPrincipal('test','a',1000).require_recent(1000+age)
        for age in (-61, 301):
            with self.assertRaises(ValueError): AccountPrincipal('test','a',1000).require_recent(1000+age)

    def test_jwt_validation_always_runs_with_bounded_revocation_cache(self):
        clock=[100.]
        claims={'uid':'a','auth_time':1000}
        user=SimpleNamespace(disabled=False,tokens_valid_after_timestamp=0)
        with patch('firebase_admin.get_app',return_value=SimpleNamespace(project_id='test')), \
             patch('firebase_admin.auth.verify_id_token',side_effect=lambda *a,**k:dict(claims)) as verify, \
             patch('firebase_admin.auth.get_user',return_value=user) as get:
            identity=FirebaseIdentity('test',clock=lambda:clock[0])
            for _ in range(10): identity.verify('x'*100)
            self.assertEqual(verify.call_count,10); self.assertEqual(get.call_count,1)
            user.disabled=True;clock[0]+=30
            with self.assertRaises(ValueError):identity.verify('x'*100)
            self.assertEqual(get.call_count,2)
            user.disabled=False;user.tokens_valid_after_timestamp=1001000;clock[0]+=30
            with self.assertRaises(ValueError):identity.verify('x'*100)
            user.tokens_valid_after_timestamp=0;clock[0]+=30
            for i in range(520):
                claims['uid']=str(i);identity.verify('x'*100)
            self.assertLessEqual(len(identity._revocation),512)

    def test_apns_burst_reuses_connection_and_token_then_refreshes(self):
        clock=[1000.]
        class Client:
            def __init__(self):self.calls=[];self.closed=False
            def post(self,url,**kwargs):
                self.calls.append((url,kwargs))
                return httpx.Response(200,request=httpx.Request('POST',url))
            def close(self):self.closed=True
        client=Client();notifications=APNs(clock=lambda:clock[0],client=client)
        environment={'BICINO_APNS_TEAM_ID':'team','BICINO_APNS_KEY_ID':'key',
                     'BICINO_APNS_PRIVATE_KEY':'fixture','BICINO_SOCIAL_ENVIRONMENT':'development'}
        with patch.dict('os.environ',environment),patch('jwt.encode',side_effect=['first','second']) as encode:
            for i in range(20):notifications.send({'environment':'development','token':'test'},'friend_request',str(i))
            self.assertEqual(encode.call_count,1)
            self.assertTrue(all(call[1]['headers']['authorization']=='bearer first' for call in client.calls))
            clock[0]+=3000
            notifications.send({'environment':'development','token':'test'},'ride_invite','next')
            self.assertEqual(encode.call_count,2)
            self.assertEqual(client.calls[-1][1]['headers']['authorization'],'bearer second')
        notifications.close();self.assertTrue(client.closed)
