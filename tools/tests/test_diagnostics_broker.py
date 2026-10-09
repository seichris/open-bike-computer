import hashlib
import http.client
import json
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from bicino_diagnostics import broker
from bicino_diagnostics.bundle import EvidenceError
from diagnostics_test_support import v1_fixture,v2_fixture


@unittest.skipUnless(shutil.which('openssl'), 'OpenSSL executable required for local TLS integration')
class BrokerTLSTestCase(unittest.TestCase):
    legacy = True
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        # macOS temp paths live under the /var -> /private/var symlink, which
        # broker roots deliberately refuse as an ancestor.
        self.parent=Path(self.temporary.name).resolve()
        self.root=self.parent/'broker'
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); self.port=sock.getsockname()[1]
        self.pairing=self.parent/'pair.json'
        broker.initialize(self.root,f'https://127.0.0.1:{self.port}',self.pairing,1,legacy=self.legacy)
        self.store=broker.BrokerStore(self.root)
        self.server=broker.BrokerHTTPServer(('127.0.0.1',self.port),self.store)
        self.thread=threading.Thread(target=self.server.serve_forever,kwargs={'poll_interval':.02},daemon=True)
        self.thread.start()
        self.config=self.store.config()
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join(timeout=3)
        self.temporary.cleanup()
    def exchange(self,method,path,body=b'',headers=None):
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
        connection=http.client.HTTPSConnection('127.0.0.1',self.port,context=context,timeout=3)
        try:
            connection.request(method,path,body=body,headers=headers or {broker.TOKEN_HEADER:self.config.get('ownerToken',self.config.get('token'))})
            response=connection.getresponse();return response.status,json.loads(response.read())
        finally:connection.close()


class DiagnosticsBrokerTests(BrokerTLSTestCase):
    def test_real_tls_queue_and_swift_uppercase_ack_idempotency(self):
        command=broker.request(self.root,'POST','/v2/commands',{'kind':'mark','target':'iphone','parameters':{'code':'other'}})
        pending=broker.request(self.root,'GET','/v2/commands')['commands']
        self.assertEqual(len(pending),1)
        ack={'id':command['id'].upper(),'state':'accepted','code':'phone_marker_saved'}
        self.assertEqual(self.exchange('POST','/v2/ack',json.dumps(ack).encode())[0],200)
        self.assertEqual(self.exchange('POST','/v2/ack',json.dumps(ack).encode())[0],200)
        self.assertEqual(broker.request(self.root,'GET','/v2/commands')['commands'],[])
        ack['code']='changed'
        self.assertEqual(self.exchange('POST','/v2/ack',json.dumps(ack).encode())[0],400)
    def test_wrong_pin_stops_before_sending_a_command(self):
        changed=dict(self.config,certificateSHA256='0'*64)
        broker.write_private(self.root/'credentials.json',json.dumps(changed).encode())
        with self.assertRaisesRegex(EvidenceError,'no credential was sent'):
            broker.request(self.root,'POST','/v2/commands',{'kind':'mark','target':'iphone','parameters':{'code':'other'}})
        self.assertEqual(self.store.pending(),[])
    def test_expiry_revokes_but_keeps_evidence_store(self):
        changed=dict(self.config,expiresAt=0)
        broker.write_private(self.root/'credentials.json',json.dumps(changed).encode())
        self.assertEqual(self.exchange('GET','/v2/status')[0],401)
        self.assertTrue((self.root/'broker.sqlite3').exists())
    def test_upload_verifies_and_duplicate_rechecks_actual_retained_bytes(self):
        inner=self.parent/'inner.zip';chunk=v1_fixture(inner)
        bundle=self.parent/'outer.zip';v2_fixture(bundle,inner,chunk)
        data=bundle.read_bytes();sha=hashlib.sha256(data).hexdigest();identifier=str(uuid.uuid4())
        headers={broker.TOKEN_HEADER:self.config['token'],'X-Content-SHA256':sha}
        for _ in range(2):
            code,response=self.exchange('PUT',f'/v2/uploads/{identifier}',data,headers)
            self.assertEqual(code,200,response)
            self.assertTrue(response['accepted'])
        self.assertEqual(len(self.store.status()['bundles']),1)
        (self.root/'bundles'/f'{identifier}.zip').write_bytes(b'corrupted')
        self.assertEqual(self.exchange('PUT',f'/v2/uploads/{identifier}',data,headers)[0],400)
    def test_wrong_hash_is_not_retained(self):
        inner=self.parent/'inner.zip';v1_fixture(inner)
        identifier=str(uuid.uuid4())
        code,_=self.exchange('PUT',f'/v2/uploads/{identifier}',inner.read_bytes(),
            {broker.TOKEN_HEADER:self.config['token'],'X-Content-SHA256':'0'*64})
        self.assertEqual(code,400)
        self.assertEqual(self.store.status()['bundles'],[])
        self.assertEqual(list((self.root/'pending').iterdir()),[])
    def test_commands_do_not_include_shell_flash_or_reboot(self):
        for kind in ('shell','flash','reboot','arbitrary','raw_payload'):
            with self.subTest(kind=kind):
                value={'kind':kind,'target':'iphone','parameters':{}}
                self.assertEqual(self.exchange('POST','/v2/commands',json.dumps(value).encode())[0],400)
    def test_pending_quota_is_bounded(self):
        for _ in range(20):self.store.enqueue('export','iphone',{})
        with self.assertRaisesRegex(EvidenceError,'pending command limit'):self.store.enqueue('export','iphone',{})
        self.assertEqual(len(self.store.pending()),8)
    def test_first_phone_binds_identity(self):
        value={'schema':2,'phoneID':str(uuid.uuid4()).upper(),'registryDigest':'a'*64,'deviceDigest':None,
            'firmwarePolicy':None,'phonePolicy':None,'collectionRunning':False}
        self.store.phone_status(value)
        self.store.phone_status(dict(value,phoneID=value['phoneID'].lower()))
        with self.assertRaisesRegex(EvidenceError,'different phone'):
            self.store.phone_status(dict(value,phoneID=str(uuid.uuid4())))
    def test_pairing_has_private_permissions_and_never_prints_token(self):
        self.assertEqual(self.pairing.stat().st_mode & 0o777,0o600)
        self.assertEqual(self.root.stat().st_mode & 0o777,0o700)
        self.assertNotIn(self.config['token'],json.dumps(self.store.status()))
        self.assertNotIn(self.config['token'],str(broker.request(self.root,'GET','/v2/status')))
    def test_certificate_uses_apple_compatible_named_curve(self):
        public_key = subprocess.run(
            ['openssl', 'x509', '-in', str(self.root/'server.crt'), '-pubkey', '-noout'],
            check=True, capture_output=True, text=True).stdout
        details = subprocess.run(
            ['openssl', 'pkey', '-pubin', '-text', '-noout'], input=public_key,
            check=True, capture_output=True, text=True).stdout
        self.assertIn('ASN1 OID: prime256v1', details)
        self.assertNotIn('Field Type:', details)
    def test_duplicate_token_header_and_chunked_requests_fail(self):
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
        with context.wrap_socket(socket.create_connection(('127.0.0.1',self.port)),server_hostname='127.0.0.1') as sock:
            payload=(f'GET /v2/status HTTP/1.1\r\nHost: localhost\r\n{broker.TOKEN_HEADER}: {self.config["token"]}\r\n'
                f'{broker.TOKEN_HEADER}: {self.config["token"]}\r\nConnection: close\r\n\r\n').encode()
            sock.sendall(payload);response=sock.recv(4096)
            self.assertIn(b'401',response)
        self.assertEqual(self.exchange('POST','/v2/phone',b'{}',
            {broker.TOKEN_HEADER:self.config['token'],'Transfer-Encoding':'chunked'})[0],400)


class DurableDiagnosticsBrokerTests(BrokerTLSTestCase):
    legacy = False

    def enroll(self, document=None, credential=None, credential_id=None, phone_id=None):
        document = document or json.loads(self.pairing.read_text())
        value = {'schema':3, 'brokerID':document['brokerID'], 'enrollmentID':document['enrollmentID'],
                 'credentialID':credential_id or str(uuid.uuid4()), 'phoneID':phone_id or str(uuid.uuid4()),
                 'credential':credential or broker.secrets.token_hex(32)}
        code, reply = self.exchange('POST','/v3/enroll',json.dumps(value).encode(),
                                   {broker.TOKEN_HEADER:document['token']})
        return code, reply, value

    def phone_status(self, phone_id):
        return {'schema':2,'phoneID':phone_id,'registryDigest':'a'*64,'deviceDigest':None,
                'firmwarePolicy':None,'phonePolicy':None,'collectionRunning':False}

    def test_enrollment_is_one_use_and_not_an_owner_or_phone_credential(self):
        document = json.loads(self.pairing.read_text())
        headers = {broker.TOKEN_HEADER:document['token']}
        self.assertEqual(self.exchange('GET','/v2/status',headers=headers)[0],401)
        self.assertEqual(self.exchange('GET','/v2/commands',headers=headers)[0],401)
        code, reply, request = self.enroll(document)
        self.assertEqual(code,200)
        self.assertTrue(reply['paired'])
        self.assertNotIn('credential',reply)
        self.assertNotIn('token',reply)
        code, _, _ = self.enroll(document,phone_id=request['phoneID'])
        self.assertEqual(code,401)
        self.assertEqual(len(self.store.paired_phones()),1)
        self.assertNotIn(request['credential'],json.dumps(self.store.paired_phones()))
        with self.store.connect() as connection:
            self.assertNotIn(request['credential'],'\n'.join(connection.iterdump()))

    def test_lost_enrollment_reply_recovers_after_deadline_and_restart(self):
        document = json.loads(self.pairing.read_text())
        code, original, value = self.enroll(document)
        self.assertEqual(code,200)
        with patch('time.time',return_value=document['expiresAt']+86400):
            reopened = broker.BrokerStore(self.root)
            self.assertEqual(reopened.enroll(document['token'],value),original)
            self.assertEqual(reopened.authenticate(value['credential']),('phone',value['credentialID'],value['phoneID']))
            self.assertEqual(self.enroll(document,credential=value['credential'],
                credential_id=value['credentialID'],phone_id=value['phoneID'])[0],200)
        self.assertEqual(len(self.store.paired_phones()),1)

    @unittest.skipUnless(shutil.which('xcrun'), 'Apple Swift toolchain required for cross-language handshake')
    def test_swift_pending_credential_and_python_tls_handshake_round_trip(self):
        pending=self.parent/'phone-pending.json';receipt_file=self.parent/'receipt.json';confirmed=self.parent/'phone-confirmed.json'
        runner=ROOT/'ios-app/scripts/run-diagnostics-broker-tests.sh'
        subprocess.run([str(runner),'--pairing-interop',str(self.pairing),str(pending)],check=True,capture_output=True,text=True)
        saved=json.loads(pending.read_text());document=saved['enrollment']
        value={'schema':3,'brokerID':saved['brokerID'],'enrollmentID':document['enrollmentID'],
               'credentialID':saved['credentialID'],'phoneID':saved['phoneID'],'credential':saved['token']}
        code,reply=self.exchange('POST','/v3/enroll',json.dumps(value).encode(),{broker.TOKEN_HEADER:document['token']})
        self.assertEqual(code,200)
        receipt_file.write_text(json.dumps(reply))
        subprocess.run([str(runner),'--confirm-interop',str(pending),str(receipt_file),str(confirmed)],check=True,capture_output=True,text=True)
        durable=json.loads(confirmed.read_text())
        self.assertNotIn('enrollment',durable)
        self.assertNotIn('expiresAt',durable)
        self.assertEqual(durable['token'],saved['token'])
        with patch('time.time',return_value=document['expiresAt']+86400):
            self.assertEqual(self.exchange('GET','/v2/commands',headers={broker.TOKEN_HEADER:durable['token']})[0],200)

    def test_expired_unused_enrollment_cannot_create_a_pair(self):
        document = json.loads(self.pairing.read_text())
        with patch('time.time',return_value=document['expiresAt']):
            self.assertEqual(self.enroll(document)[0],401)
        self.assertEqual(self.store.paired_phones(),[])

    def test_phone_scope_cannot_enqueue_commands_or_impersonate_another_phone(self):
        code, _, request = self.enroll()
        self.assertEqual(code,200)
        header = {broker.TOKEN_HEADER:request['credential']}
        self.assertEqual(self.exchange('POST','/v2/commands',b'{}',header)[0],403)
        self.assertEqual(self.exchange('GET','/v2/status',headers=header)[0],403)
        self.assertEqual(self.exchange('POST','/v2/phone',json.dumps(self.phone_status(str(uuid.uuid4()))).encode(),header)[0],400)
        self.assertEqual(self.exchange('POST','/v2/phone',json.dumps(self.phone_status(request['phoneID'])).encode(),header)[0],200)
        self.assertEqual(broker.request(self.root,'GET','/v2/status')['phone']['phoneID'],request['phoneID'])
        self.assertEqual(self.exchange('POST','/v2/phone',b'{}')[0],403)

    def test_durable_upload_recovers_lost_ack_after_daily_expiry(self):
        document = json.loads(self.pairing.read_text())
        code, _, request = self.enroll(document)
        self.assertEqual(code,200)
        inner=self.parent/'inner.zip';chunk=v1_fixture(inner)
        bundle=self.parent/'outer.zip';v2_fixture(bundle,inner,chunk)
        data=bundle.read_bytes();digest=hashlib.sha256(data).hexdigest();identifier=str(uuid.uuid4())
        header={broker.TOKEN_HEADER:request['credential'],'X-Content-SHA256':digest}
        self.assertEqual(self.exchange('PUT',f'/v2/uploads/{identifier}',data,header)[0],200)
        with patch('time.time',return_value=document['expiresAt']+86400):
            self.assertEqual(self.exchange('PUT',f'/v2/uploads/{identifier}',data,header)[0],200)
        self.assertEqual(len(self.store.status()['bundles']),1)
        self.assertEqual(hashlib.sha256((self.root/'bundles'/f'{identifier}.zip').read_bytes()).hexdigest(),digest)

    def test_revocation_survives_restart_and_enrollment_replay_cannot_restore_it(self):
        document=json.loads(self.pairing.read_text())
        code, _, value=self.enroll(document)
        self.assertEqual(code,200)
        self.store.revoke(value['credentialID'])
        reopened=broker.BrokerStore(self.root)
        self.assertIsNone(reopened.authenticate(value['credential']))
        with self.assertRaises(broker.EvidenceError):reopened.enroll(document['token'],value)
        self.assertEqual(self.exchange('GET','/v2/commands',headers={broker.TOKEN_HEADER:value['credential']})[0],401)
        self.assertTrue(self.root.joinpath('bundles').is_dir())

    def test_revocation_after_authentication_still_blocks_status_and_upload_commit(self):
        code, _, request=self.enroll()
        self.assertEqual(code,200)
        self.assertIsNotNone(self.store.authenticate(request['credential']))
        self.store.revoke(request['credentialID'])
        with self.assertRaises(broker.PairingAuthorizationError):
            self.store.phone_status(self.phone_status(request['phoneID']),request['credentialID'])
        inner=self.parent/'inner.zip';chunk=v1_fixture(inner)
        incoming=self.parent/'upload.zip';v2_fixture(incoming,inner,chunk)
        digest=hashlib.sha256(incoming.read_bytes()).hexdigest()
        with self.assertRaises(broker.PairingAuthorizationError):
            self.store.accept_upload(str(uuid.uuid4()),incoming,digest,request['credentialID'])
        self.assertEqual(self.store.status()['bundles'],[])
        self.assertIsNone(self.store.status()['phone'])
        self.assertTrue(incoming.exists())

    def test_one_phone_until_revocation_and_old_commands_do_not_cross_the_pair_boundary(self):
        code, _, first=self.enroll()
        self.assertEqual(code,200)
        self.store.phone_status(self.phone_status(first['phoneID']))
        command=self.store.enqueue('export','iphone',{})
        output=self.parent/'second.json';self.store.create_enrollment(output,1)
        second=json.loads(output.read_text())
        self.assertEqual(self.enroll(second)[0],401)
        self.store.revoke(first['credentialID'])
        self.assertEqual(self.store.pending(),[])
        self.assertIsNone(self.store.status()['phone'])
        self.assertEqual(self.store.status()['commands'][0]['result']['code'],'pairing_revoked')
        self.assertEqual(self.enroll(second)[0],200)
        self.assertNotEqual(next(p['credentialID'] for p in self.store.paired_phones() if p['revokedAt'] is None),first['credentialID'])

    def test_phone_can_only_revoke_its_own_credential(self):
        code, _, request=self.enroll()
        self.assertEqual(code,200)
        header={broker.TOKEN_HEADER:request['credential']}
        value={'schema':3,'credentialID':str(uuid.uuid4()),'phoneID':request['phoneID']}
        self.assertEqual(self.exchange('POST','/v3/unpair',json.dumps(value).encode(),header)[0],400)
        value['credentialID']=request['credentialID']
        self.assertEqual(self.exchange('POST','/v3/unpair',json.dumps(value).encode(),header)[0],200)
        self.assertIsNone(self.store.authenticate(request['credential']))
        self.assertEqual(broker.request(self.root,'GET','/v2/status')['schema'],2)

    def test_all_revoke_invalidates_unused_files_without_deleting_inbox(self):
        document=json.loads(self.pairing.read_text())
        self.store.revoke()
        self.assertEqual(self.enroll(document)[0],401)
        self.assertTrue((self.root/'broker.sqlite3').exists())
        self.assertEqual(broker.request(self.root,'GET','/v2/status')['schema'],2)

    def test_enrollment_files_are_private_bounded_and_never_overwrite(self):
        first=self.pairing.read_bytes()
        with self.assertRaises(broker.EvidenceError):self.store.create_enrollment(self.pairing,1)
        self.assertEqual(self.pairing.read_bytes(),first)
        for index in range(7):self.store.create_enrollment(self.parent/f'next-{index}.json',1)
        with self.assertRaisesRegex(broker.EvidenceError,'limit'):self.store.create_enrollment(self.parent/'overflow.json',1)
        self.assertFalse((self.parent/'overflow.json').exists())
        self.assertEqual(self.pairing.stat().st_mode & 0o777,0o600)

    def test_repeated_explicit_replacements_bound_history_without_restoring_revoked_credentials(self):
        first_document=json.loads(self.pairing.read_text())
        first=None
        for index in range(40):
            output=self.parent/f'replace-{index}.json'
            if index == 0:document=first_document
            else:
                self.store.create_enrollment(output,1)
                document=json.loads(output.read_text())
            value={'schema':3,'brokerID':document['brokerID'],'enrollmentID':document['enrollmentID'],
                   'credentialID':str(uuid.uuid4()),'phoneID':str(uuid.uuid4()),'credential':broker.secrets.token_hex(32)}
            self.store.enroll(document['token'],value)
            if first is None:first=value
            self.store.revoke(value['credentialID'])
        self.assertLessEqual(len(self.store.paired_phones()),32)
        self.assertIsNone(self.store.authenticate(first['credential']))
        with self.assertRaises(broker.EvidenceError):self.store.enroll(first_document['token'],first)
        self.assertEqual(self.store.status()['bundles'],[])

    def test_completed_history_retains_unexpired_replays_but_does_not_fill_forever(self):
        now=int(time.time())
        with patch('time.time',return_value=now):
            for _ in range(100):
                command=self.store.enqueue('export','iphone',{})
                self.store.acknowledge({'id':command['id'],'state':'accepted','code':'handoff_requested'})
            with self.assertRaisesRegex(broker.EvidenceError,'history'):self.store.enqueue('export','iphone',{})
        with patch('time.time',return_value=now+3601):
            self.store.enqueue('export','iphone',{})
        self.assertEqual(len(self.store.status()['commands']),1)


class DiagnosticsBrokerUpgradeTests(BrokerTLSTestCase):
    def test_legacy_phone_keeps_its_original_deadline_until_durable_enrollment(self):
        old=self.config.copy()
        result=self.store.upgrade_credentials()
        self.assertTrue(result['upgraded'])
        self.assertEqual(self.store.authenticate(old['token']),('legacy',None,None))
        output=self.parent/'new.json';self.store.create_enrollment(output,1)
        document=json.loads(output.read_text())
        value={'schema':3,'brokerID':document['brokerID'],'enrollmentID':document['enrollmentID'],
               'credentialID':str(uuid.uuid4()),'phoneID':str(uuid.uuid4()),'credential':broker.secrets.token_hex(32)}
        self.store.enroll(document['token'],value)
        self.assertIsNone(self.store.authenticate(old['token']))
        self.store.revoke(value['credentialID'])
        self.assertIsNone(broker.BrokerStore(self.root).authenticate(old['token']))
        self.assertEqual(self.store.config()['legacy']['expiresAt'],old['expiresAt'])

    def test_expired_legacy_pairing_can_upgrade_locally_without_renewing_its_bearer(self):
        from bicino_diagnostics import cli
        expired=dict(self.config,expiresAt=0)
        broker.write_private(self.root/'credentials.json',json.dumps(expired).encode())
        args=cli.parser().parse_args(['diag','--broker-root',str(self.root),'broker','upgrade'])
        result, code=cli.run(args)
        self.assertEqual(code,0)
        self.assertTrue(result['upgraded'])
        self.assertIsNone(self.store.authenticate(expired['token']))
        self.assertEqual(self.store.config()['legacy']['expiresAt'],0)
        self.assertEqual(broker.request(self.root,'GET','/v2/status')['schema'],2)

    def test_migration_probe_is_nonsecret_and_sends_no_bearer(self):
        sent_headers=[]
        original=http.client.HTTPSConnection.request
        def recording_request(connection,method,path,body=None,headers=None,**kwargs):
            sent_headers.append(dict(headers or {}))
            return original(connection,method,path,body=body,headers=headers or {},**kwargs)
        with patch.object(http.client.HTTPSConnection,'request',recording_request):
            with patch.object(broker.BrokerHandler,'credential',side_effect=AssertionError('probe must not authenticate')):
                result=broker.request(self.root,'GET','/v3/info')
        self.assertEqual(result,{'schema':3,'durablePairing':True,'credentialSchema':2})
        self.assertEqual(len(sent_headers),1)
        self.assertNotIn(broker.TOKEN_HEADER,sent_headers[0])
        changed=dict(self.config,certificateSHA256='0'*64)
        broker.write_private(self.root/'credentials.json',json.dumps(changed).encode())
        with patch.object(http.client.HTTPSConnection,'request',side_effect=AssertionError('wrong pin must stop before HTTP')):
            with self.assertRaisesRegex(broker.EvidenceError,'TLS pin mismatch'):
                broker.request(self.root,'GET','/v3/info')

    def test_cli_upgrade_requires_a_matching_running_server_before_mutation(self):
        from bicino_diagnostics import cli
        args=cli.parser().parse_args(['diag','--broker-root',str(self.root),'broker','upgrade'])
        before=(self.root/'credentials.json').read_bytes()
        with patch.object(broker,'request',side_effect=broker.EvidenceError('broker request rejected (404)')):
            with self.assertRaises(broker.EvidenceError):cli.run(args)
        self.assertEqual((self.root/'credentials.json').read_bytes(),before)
        result, code=cli.run(args)
        self.assertEqual(code,0)
        self.assertTrue(result['upgraded'])
        self.assertEqual(result['schema'],3)


if __name__=='__main__':unittest.main()
