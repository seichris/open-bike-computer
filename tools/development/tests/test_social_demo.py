import importlib.machinery
import importlib.util
import math
from pathlib import Path
import unittest
from unittest.mock import patch
import types

ROOT = Path(__file__).resolve().parents[3]
loader = importlib.machinery.SourceFileLoader('social_demo', str(ROOT/'tools/social-demo'))
spec = importlib.util.spec_from_loader(loader.name, loader)
demo = importlib.util.module_from_spec(spec)
loader.exec_module(demo)


class SocialDemoTests(unittest.TestCase):
    def test_only_the_development_project_can_run(self):
        demo.guard_environment({'BICINO_SOCIAL_ENVIRONMENT':'development','BICINO_FIREBASE_PROJECT_ID':'bicino-dev'})
        for environment in ({}, {'BICINO_SOCIAL_ENVIRONMENT':'production','BICINO_FIREBASE_PROJECT_ID':'bicino-dev'},
                            {'BICINO_SOCIAL_ENVIRONMENT':'development','BICINO_FIREBASE_PROJECT_ID':'bicino-prod'}):
            with self.assertRaises(demo.DemoError): demo.guard_environment(environment)
        self.assertEqual(demo.ORIGIN, 'https://maps-dev.8o.vc/v1/social')
        self.assertIn('social-dev', demo.CONTAINER)

    def test_demo_identity_namespace_is_stable_distinct_and_valid(self):
        identities = [demo.identity('chrisusername', rider[0]) for rider in demo.RIDERS]
        self.assertEqual(len(set(uid for uid, _ in identities)), 3)
        self.assertEqual(len(set(name for _, name in identities)), 3)
        for slug, _, _ in demo.RIDERS:
            uid, name = demo.identity('chrisusername', slug)
            self.assertEqual((uid,name), demo.identity('chrisusername',slug))
            self.assertTrue(uid.startswith('bicino-dev-demo-'))
            self.assertRegex(name, r'^[a-z][a-z0-9_]{2,29}$')
            self.assertNotEqual((uid,name),demo.identity('another_rider',slug))
        for target in ('../production','@chris','', 'support/name'):
            with self.assertRaises(demo.DemoError): demo.identity(target,'ava')
        with self.assertRaises(demo.DemoError): demo.identity('chris','real_person')

    def test_synthetic_tracks_and_stats_stay_within_live_api_bounds(self):
        for slug, _, speed in demo.RIDERS:
            for elapsed in (0, 3, 19, 20, 60, 109, 110, 149, 150, 3600, 14400):
                fix=demo.sample(slug,elapsed,1000000,12,'epoch','target')
                if fix is None:
                    self.assertEqual(slug,'cleo'); continue
                self.assertTrue(all(math.isfinite(value) for value in fix.values() if isinstance(value,(float,int))))
                self.assertTrue(31.23 < fix['latitude'] < 31.24)
                self.assertTrue(121.44 < fix['longitude'] < 121.46)
                self.assertTrue(0 <= fix['course'] < 360)
                self.assertEqual(fix['speed'],speed)
                self.assertEqual(fix['distanceMeters'],elapsed*speed)
                self.assertEqual(fix['epochs'],{'target':'epoch'})
                self.assertNotIn('routeHash',fix)
        self.assertGreater(demo.sample('ava',60,0,0,'e','t')['distanceMeters'],demo.sample('ben',60,0,0,'e','t')['distanceMeters'])

    def test_intermittent_rider_exercises_fade_and_removal_then_resumes(self):
        self.assertIsNotNone(demo.sample('cleo',19,0,0,'e','t'))
        for elapsed in (20,35,79,90,109): self.assertIsNone(demo.sample('cleo',elapsed,0,0,'e','t'))
        self.assertIsNotNone(demo.sample('cleo',110,0,0,'e','t'))
        self.assertIsNotNone(demo.sample('cleo',150,0,0,'e','t'))

    def test_custom_signin_checks_signed_claims_without_a_local_id_field(self):
        account = demo.DemoAccount(None, None, {'target':'chrisusername','apiKey':'public-development-key'},'ava','Demo Ava')
        class Response:
            status_code=200
            def json(self): return {'idToken':'short-lived-test-token','expiresIn':'3600'}
        class Client:
            def post(self,url,params,json):
                self.url=url
                self.body=json
                return Response()
        client=Client(); account.client=client
        class Auth:
            @staticmethod
            def create_custom_token(uid,app):
                if uid != account.uid: raise AssertionError('Cannot mint another identity')
                return b'custom-test-token'
            @staticmethod
            def verify_id_token(token,app): return {'uid':account.uid,'aud':'bicino-dev'}
        with patch.dict('sys.modules',{'firebase_admin':types.SimpleNamespace(auth=Auth)}): account.authenticate()
        self.assertEqual(account.token,'short-lived-test-token')
        self.assertEqual(client.url,'https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken')
        self.assertEqual(client.body['token'],'custom-test-token')
        account.token_deadline=0
        Auth.verify_id_token=staticmethod(lambda token,app: {'uid':'a-real-user','aud':'bicino-dev'})
        with patch.dict('sys.modules',{'firebase_admin':types.SimpleNamespace(auth=Auth)}):
            with self.assertRaises(demo.DemoError): account.authenticate()

    def test_missing_synthetic_user_uses_custom_signin_without_admin_create(self):
        class NotFound(Exception): pass
        user = types.SimpleNamespace(display_name=None, email=None, provider_data=[])
        class Auth:
            UserNotFoundError = NotFound
            exists = False
            @classmethod
            def get_user(cls, uid, app):
                if not cls.exists: raise NotFound()
                return user
            @staticmethod
            def create_user(**kwargs): raise AssertionError('Runtime IAM must not gain user-create permissions')
        account = demo.DemoAccount(None, None, {'target':'chrisusername'}, 'ava', 'Demo Ava')
        account.authenticate = lambda: setattr(Auth, 'exists', True)
        def call(method,path,body=None):
            if method == 'GET': return {'id':'demo-profile','username':None,'displayName':'Bicino rider','version':1}
            return {'id':'demo-profile', 'username':body['username'], 'displayName':body['displayName']}
        account.call = call
        with patch.dict('sys.modules', {'firebase_admin':types.SimpleNamespace(auth=Auth)}):
            profile = account.ensure_profile()
        self.assertTrue(Auth.exists)
        self.assertEqual(profile['displayName'],'Demo Ava')
        self.assertEqual(profile['username'],account.username)
        # A real provider binding cannot be taken over as a synthetic rider.
        user.email='someone@example.com'
        with patch.dict('sys.modules', {'firebase_admin':types.SimpleNamespace(auth=Auth)}):
            with self.assertRaises(demo.DemoError): account.ensure_profile()

    def test_errors_cannot_echo_tokens_or_provider_bodies(self):
        self.assertEqual(demo.safe_error(demo.DemoError('403:friendship_required')),'403:friendship_required')
        sensitive='https://provider.example/?key=never-print-this'
        self.assertEqual(demo.safe_error(ValueError(sensitive)),'ValueError')
        self.assertEqual(demo.safe_error(demo.DemoError(sensitive)),'DemoError')
        self.assertNotIn('never-print',demo.safe_error(RuntimeError(sensitive)))

    def test_emoji_avatar_uses_versioned_profile_api_and_keeps_existing_picture(self):
        class Response:
            status_code = 200
            def json(self): return {'id':'demo-profile','avatarID':'new-avatar','version':8}
        class Client:
            def request(self, method, url, **kwargs):
                self.sent = (method, url, kwargs)
                return Response()
        client = Client()
        account = demo.DemoAccount(client, None, {'target':'chrisusername'}, 'ava', 'Demo Ava')
        account.authenticate = lambda: None
        account.token = 'short-lived-test-token'
        png = b'\x89PNG\r\n\x1a\n' + b'synthetic-image-fixture'
        with patch.object(demo.Path, 'read_bytes', return_value=png):
            result = account.ensure_avatar({'version':7,'avatarID':None})
        method, url, payload = client.sent
        self.assertEqual((method,url),('PUT',demo.ORIGIN+'/me/avatar'))
        self.assertEqual(payload['params'],{'version':7})
        self.assertEqual(payload['content'],png)
        self.assertNotIn('json',payload)
        self.assertEqual(payload['headers']['Content-Type'],'image/png')
        self.assertEqual(result['avatarID'],'new-avatar')
        with patch.object(demo.Path,'read_bytes',side_effect=AssertionError('Do not replace an existing avatar')):
            self.assertEqual(account.ensure_avatar(result),result)


if __name__ == '__main__': unittest.main()
