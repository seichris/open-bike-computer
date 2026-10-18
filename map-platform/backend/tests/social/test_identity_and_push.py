import threading
import time
import unittest
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import patch
import httpx
from map_platform.user_auth import AccountPrincipal, FirebaseIdentity, IdentityUnavailable
from map_platform.social.worker import APNs


def token(uid):
    return uid.ljust(100, '.')


def claims(token, **_):
    return {'uid': token.rstrip('.'), 'auth_time': 1000}


def healthy_user(*_, **__):
    return SimpleNamespace(disabled=False, tokens_valid_after_timestamp=0)


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

    def identity(self, **options):
        with patch('firebase_admin.get_app', return_value=SimpleNamespace(project_id='test')):
            return FirebaseIdentity('test', **options)

    def test_provider_calls_are_bounded_by_explicit_http_timeout(self):
        with patch('firebase_admin.get_app', side_effect=ValueError()), \
             patch('firebase_admin.initialize_app', return_value=SimpleNamespace(project_id='test')) as initialize:
            FirebaseIdentity('test')
        self.assertEqual(initialize.call_args.kwargs['options'], {'projectId': 'test', 'httpTimeout': 5})

    def test_blocked_lookup_does_not_block_cached_or_cold_users(self):
        release, entered, calls = threading.Event(), threading.Event(), Counter()
        def get_user(uid, **_):
            calls[uid] += 1
            if uid == 'slow':
                entered.set()
                if not release.wait(5):
                    raise AssertionError('slow lookup was never released')
            return healthy_user()
        with patch('firebase_admin.auth.verify_id_token', side_effect=claims), \
             patch('firebase_admin.auth.get_user', side_effect=get_user):
            identity = self.identity(lookup_wait=0.2)
            identity.verify(token('cached'))
            with ThreadPoolExecutor(max_workers=2) as pool:
                slow = pool.submit(identity.verify, token('slow'))
                self.assertTrue(entered.wait(2))
                started = time.monotonic()
                self.assertEqual(identity.verify(token('cached')).uid, 'cached')
                self.assertEqual(identity.verify(token('cold')).uid, 'cold')
                self.assertLess(time.monotonic()-started, 1.0)
                # A concurrent request for the blocked UID joins the same lookup and
                # gives up as temporarily unavailable, never as revoked.
                with self.assertRaises(IdentityUnavailable):
                    identity.verify(token('slow'))
                release.set()
                self.assertEqual(slow.result(timeout=5).uid, 'slow')
            identity.verify(token('slow'))
        self.assertEqual(calls['slow'], 1)
        self.assertEqual(calls['cached'], 1)

    def test_provider_outage_is_unavailable_and_never_cached_as_revocation(self):
        from firebase_admin import auth, exceptions
        failures = [exceptions.UnavailableError('down'), exceptions.DeadlineExceededError('slow'),
                    exceptions.InternalError('fault'), ConnectionError('reset')]
        with patch('firebase_admin.auth.verify_id_token', side_effect=claims), \
             patch('firebase_admin.auth.get_user', side_effect=failures + [healthy_user()]) as get:
            identity = self.identity()
            for _ in failures:
                with self.assertRaises(IdentityUnavailable):
                    identity.verify(token('rider'))
            self.assertEqual(identity.verify(token('rider')).uid, 'rider')
            self.assertEqual(get.call_count, len(failures)+1)
        with patch('firebase_admin.auth.verify_id_token', side_effect=claims), \
             patch('firebase_admin.auth.get_user', side_effect=auth.UserNotFoundError('gone')):
            with self.assertRaises(ValueError) as revoked:
                self.identity().verify(token('deleted'))
            self.assertNotIsInstance(revoked.exception, IdentityUnavailable)
        with patch('firebase_admin.auth.verify_id_token', side_effect=auth.CertificateFetchError('keys', None)):
            with self.assertRaises(IdentityUnavailable):
                self.identity().verify(token('rider'))

    def test_concurrent_lookup_capacity_is_bounded(self):
        release, entered = threading.Event(), threading.Event()
        def get_user(uid, **_):
            entered.set(); release.wait(5)
            return healthy_user()
        with patch('firebase_admin.auth.verify_id_token', side_effect=claims), \
             patch('firebase_admin.auth.get_user', side_effect=get_user):
            identity = self.identity(lookup_capacity=1)
            with ThreadPoolExecutor(max_workers=1) as pool:
                first = pool.submit(identity.verify, token('one'))
                self.assertTrue(entered.wait(2))
                with self.assertRaises(IdentityUnavailable):
                    identity.verify(token('two'))
                release.set()
                first.result(timeout=5)

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
