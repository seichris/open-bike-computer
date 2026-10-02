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
import uuid

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from bicino_diagnostics import broker
from bicino_diagnostics.bundle import EvidenceError
from diagnostics_test_support import v1_fixture,v2_fixture


@unittest.skipUnless(shutil.which('openssl'), 'OpenSSL executable required for local TLS integration')
class DiagnosticsBrokerTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.parent=Path(self.temporary.name)
        self.root=self.parent/'broker'
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); self.port=sock.getsockname()[1]
        self.pairing=self.parent/'pair.json'
        broker.initialize(self.root,f'https://127.0.0.1:{self.port}',self.pairing,1)
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
            connection.request(method,path,body=body,headers=headers or {broker.TOKEN_HEADER:self.config['token']})
            response=connection.getresponse();return response.status,json.loads(response.read())
        finally:connection.close()
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

if __name__=='__main__':unittest.main()
