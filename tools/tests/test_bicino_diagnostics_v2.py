"""Executable acquisition, privacy, resumption and local-agent boundary tests."""
import base64
import hashlib
import http.client
import io
import json
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from bicino_diagnostics import broker, bundle
from bicino_diagnostics.cli import contract
from test_ride_diagnostics import (event, firmware_event, bundle_manifest,
                                  required_sidecars, APP_STREAM_PATH,
                                  APP_CAPTURE_ID, DEVICE_DIGEST)


def checksum_zip(members):
    entries = dict(members)
    entries['checksums.sha256'] = ''.join(
        f'{hashlib.sha256(raw).hexdigest()}  {name}\n' for name, raw in sorted(entries.items())
    ).encode()
    target = io.BytesIO()
    with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name, raw in entries.items(): archive.writestr(name, raw)
    return target.getvalue()


def fixture(*, missing=False, received=True, loss=0):
    phone = b''.join((json.dumps(event(sequence=x))+'\n').encode() for x in range(3))
    device = (json.dumps(firmware_event())+'\n').encode()
    digest = hashlib.sha256(device).hexdigest()
    device_path = f'device/{DEVICE_DIGEST}/7/events-000001-{digest[:16]}.jsonl'
    streams = {APP_STREAM_PATH: phone}
    if not missing: streams[device_path] = device
    manifest = bundle_manifest(streams)
    manifest['droppedEventCount'] = loss
    members = dict(streams, **required_sidecars(manifest))
    members['manifest.json'] = json.dumps(manifest).encode()
    v1 = checksum_zip(members)
    index = {'schema': 1, 'source': 'firmware', 'bootSequence': 7, 'activeChunk': 2,
             'stats': {'enqueued': 1, 'written': 1, 'dropped': 0, 'storageErrors': 0},
             'chunks': [{'bootSequence': 7, 'chunk': 1, 'bytes': len(device), 'sha256': digest}]}
    raw_index = json.dumps(index).encode()
    acquisition = {'schema': 2, 'id': str(uuid.uuid4()), 'deviceDigest': DEVICE_DIGEST,
                   'captureID': APP_CAPTURE_ID, 'index': index,
                   'rawIndex': base64.b64encode(raw_index).decode(),
                   'indexSHA256': hashlib.sha256(raw_index).hexdigest(),
                   'received': [f'7-1-{digest}'] if received else [], 'state': 'delivered' if received else 'interrupted',
                   'createdAt': 812345678, 'updatedAt': 812345679}
    outer = {'evidence/v1.zip': v1, 'acquisition.json': json.dumps(acquisition).encode(),
             'coverage.json': b'{"delivery":"not_trusted_without_raw_validation"}'}
    outer['manifest.json'] = json.dumps({'schema': 2, 'kind': 'bicino-diagnostics-handoff',
        'id': acquisition['id'], 'contractSHA256': 'a'*64, 'members': sorted(outer)}).encode()
    return checksum_zip(outer)


class EvidenceV2Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
    def tearDown(self): self.tmp.cleanup()
    def save(self, raw):
        path = self.root / 'bundle.zip'; path.write_bytes(raw); return path
    def test_generated_contract_is_current(self):
        subprocess.run([sys.executable, 'tools/generate_diagnostics_contract.py', '--check'], cwd=ROOT, check=True, stdout=subprocess.PIPE)
    def test_real_producer_passes_host_validator(self):
        executable = self.root / 'health'
        subprocess.run(['c++', '-std=c++17', str(ROOT / 'esp32/tools/tests/test_diagnostics_health_producer.cpp'), '-o', str(executable)], check=True)
        value = json.loads(subprocess.check_output([executable]))
        # Boot identity is normally attached by the recorder, after formatting.
        value['fields'].update(bootSequence=7, firmwareFingerprint='A1B2C3D4')
        bundle.legacy.validate_jsonl((json.dumps(value)+'\n').encode(), 'fixture', 'firmware')
        self.assertIs(value['fields']['recorderReady'], True)
    def test_complete_delivery_is_not_complete_recording(self):
        summary, events = bundle.read(self.save(fixture()))
        self.assertEqual(summary['deliveryState'], 'complete_for_inventory')
        self.assertEqual(summary['recordingCoverage'], 'not_proven_complete')
        self.assertEqual(summary['eventCount'], 4)
        self.assertEqual(set(summary['sourceCounts']), {'ios','firmware'})
        self.assertEqual(events[0]['evidence']['bundleSHA256'], summary['bundleSHA256'])
        self.assertGreaterEqual(events[0]['evidence']['line'], 1)
    def test_missing_raw_overrides_claimed_receipt(self):
        summary, _ = bundle.read(self.save(fixture(missing=True)))
        self.assertEqual(summary['deliveryState'], 'incomplete')
        self.assertEqual(len(summary['missingRawChunks']), 1)
    def test_missing_receipt_is_explicit(self):
        summary, _ = bundle.read(self.save(fixture(received=False)))
        self.assertEqual(summary['deliveryState'], 'incomplete')
    def test_loss_changes_coverage(self):
        summary, _ = bundle.read(self.save(fixture(loss=2)))
        self.assertEqual(summary['recordingCoverage'], 'degraded')
    def test_bounded_scoped_query(self):
        path = self.save(fixture())
        first = bundle.query(path, source='ios', limit=2)
        self.assertEqual(len(first['events']), 2)
        second = bundle.query(path, source='ios', limit=2, cursor=first['nextCursor'])
        self.assertEqual(len(second['events']), 1); self.assertIsNone(second['nextCursor'])
        with self.assertRaises(bundle.EvidenceError): bundle.query(path, source='firmware', cursor=first['nextCursor'])
        with self.assertRaises(bundle.EvidenceError): bundle.query(path, limit=501)
    def test_corrupt_member_rejected(self):
        raw = fixture(); source = zipfile.ZipFile(io.BytesIO(raw)); out = io.BytesIO()
        with zipfile.ZipFile(out, 'w') as z:
            for name in source.namelist(): z.writestr(name, source.read(name)+(b' ' if name=='coverage.json' else b''))
        with self.assertRaises(bundle.EvidenceError): bundle.read(self.save(out.getvalue()))
    def test_zip_path_duplicate_and_opaque_artifact_rejected(self):
        for path in ('../outside', '/absolute', 'restricted/core.bin'):
            source = zipfile.ZipFile(io.BytesIO(fixture())); out = io.BytesIO()
            with zipfile.ZipFile(out, 'w') as z:
                for name in source.namelist(): z.writestr(name, source.read(name))
                z.writestr(path, b'x')
            with self.assertRaises(bundle.EvidenceError): bundle.read(self.save(out.getvalue()))
    def test_duplicate_json_key_and_nonfinite_rejected(self):
        for raw in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":Infinity}'):
            with self.assertRaises(bundle.EvidenceError): bundle.strict_json(raw)
    def test_acquisition_hash_and_scalar_types(self):
        source = zipfile.ZipFile(io.BytesIO(fixture()))
        acq = json.loads(source.read('acquisition.json'))
        acq['index']['chunks'][0]['bytes'] = True
        with self.assertRaises(bundle.EvidenceError): bundle.validate_acquisition(acq)


class BrokerV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which('openssl'): raise unittest.SkipTest('openssl not installed')
        cls.identity_tmp = tempfile.TemporaryDirectory()
        cls.identity = Path(cls.identity_tmp.name)
        broker.initialize(cls.identity, 'https://127.0.0.1:8123', 'LetItRide.BikeComputer.dev')
    @classmethod
    def tearDownClass(cls): cls.identity_tmp.cleanup()
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        for path in self.identity.iterdir(): shutil.copy(path, self.root / path.name)
        self.store = broker.Store(self.root)
    def tearDown(self): self.tmp.cleanup()
    def job(self, kind='collect', args=None):
        value = {'id': str(uuid.uuid4()), 'kind':kind, 'arguments':args or {}, 'deviceDigest':DEVICE_DIGEST,
                 'expiresAtEpoch':int(time.time())+300}
        self.store.enqueue(value); self.store.next_command(); return value['id']
    def test_role_tokens_are_distinct_and_enrollment_does_not_leak_control(self):
        value = broker.load_json(self.root / 'enrollment.json')
        self.assertNotIn('controlToken', value); self.assertNotIn('phoneToken', value)
        self.assertNotEqual(value['token'], self.store.config['controlToken'])
    def test_executable_actions_and_wrong_shape_rejected(self):
        with self.assertRaises(broker.BrokerError): self.job('shell', {'command':'echo unsafe'})
        with self.assertRaises(broker.BrokerError): self.job('capture.start', {'durationSeconds':86400})
    def test_idempotent_command_and_result(self):
        identity = self.job('mark', {'code':'other'})
        result = {'ok':True,'incidentID':str(uuid.uuid4()),'devicePersistence':'pending_or_unavailable'}
        first = self.store.complete(identity,result); self.assertEqual(self.store.complete(identity,result), first)
        with self.assertRaises(broker.BrokerError): self.store.complete(identity, {'ok':False,'code':'failed'})
    def test_no_collect_success_without_verified_artifact(self):
        identity = self.job()
        with self.assertRaises(broker.BrokerError): self.store.complete(identity, {'ok':True,'artifactSHA256':'a'*64})
    def test_resume_and_exact_idempotent_upload(self):
        raw=fixture(); digest=hashlib.sha256(raw).hexdigest(); identity=self.job()
        split=1000
        self.store.append_upload(identity,digest,len(raw),0,raw[:split],hashlib.sha256(raw[:split]).hexdigest())
        self.assertEqual(broker.Store(self.root).upload_status(identity)['received'], split)
        final=self.store.append_upload(identity,digest,len(raw),split,raw[split:],hashlib.sha256(raw[split:]).hexdigest())
        self.assertTrue(final['complete']); self.assertEqual(self.store.upload_status(identity),final)
        self.assertEqual(self.store.append_upload(identity,digest,len(raw),split,raw[split:],hashlib.sha256(raw[split:]).hexdigest()),final)
        self.assertEqual(self.store.path('artifacts',digest,'.zip').read_bytes(),raw)
        self.store.complete(identity,{'ok':True,'artifactSHA256':digest})
    def test_reject_bad_offset_slice_or_replacement(self):
        identity=self.job(); raw=fixture(); digest=hashlib.sha256(raw).hexdigest()
        with self.assertRaises(broker.BrokerError): self.store.append_upload(identity,digest,len(raw),1,raw[:10],hashlib.sha256(raw[:10]).hexdigest())
        with self.assertRaises(broker.BrokerError): self.store.append_upload(identity,digest,len(raw),0,raw[:10],'a'*64)
        self.store.append_upload(identity,digest,len(raw),0,raw[:10],hashlib.sha256(raw[:10]).hexdigest())
        with self.assertRaises(broker.BrokerError): self.store.append_upload(identity,'b'*64,len(raw),10,raw[10:20],hashlib.sha256(raw[10:20]).hexdigest())
    def test_recover_uncommitted_extra_bytes(self):
        identity=self.job(); raw=fixture(); digest=hashlib.sha256(raw).hexdigest()
        self.store.append_upload(identity,digest,len(raw),0,raw[:100],hashlib.sha256(raw[:100]).hexdigest())
        with self.store.path('uploads',identity,'.part').open('ab') as f: f.write(raw[100:300])
        self.assertEqual(self.store.upload_status(identity)['received'],100)
        self.assertEqual(self.store.path('uploads',identity,'.part').stat().st_size,100)
    def test_recover_rename_before_receipt(self):
        identity=self.job(); raw=fixture(); digest=hashlib.sha256(raw).hexdigest()
        original=broker.atomic_json
        def interrupted(path,value):
            if path==self.store.path('uploads',identity) and value.get('complete'): raise OSError('simulated power cut')
            original(path,value)
        with patch.object(broker,'atomic_json',side_effect=interrupted):
            with self.assertRaises(OSError): self.store.append_upload(identity,digest,len(raw),0,raw,digest)
        restored=broker.Store(self.root).upload_status(identity)
        self.assertTrue(restored['complete'])
    def test_bad_final_artifact_never_reports_complete(self):
        identity=self.job(); raw=b'not a zip'; digest=hashlib.sha256(raw).hexdigest()
        with self.assertRaises(broker.BrokerError): self.store.append_upload(identity,digest,len(raw),0,raw,digest)
        self.assertFalse(self.store.upload_status(identity)['complete'])
        self.assertEqual(self.store.upload_status(identity)['received'],0)
        self.assertFalse(self.store.path('artifacts',digest,'.zip').exists())
    def test_symlink_state_rejected(self):
        alias=self.root/'alias'; alias.symlink_to(self.root/'config.json')
        with self.assertRaises(broker.BrokerError): broker.load_json(alias)
    def test_expired_and_oversized_queue_limits(self):
        identity=self.job('mark',{'code':'other'}); value=self.store.job(identity)
        value['expiresAtEpoch']=int(time.time())-1; broker.atomic_json(self.store.path('jobs',identity),value)
        self.assertIsNone(self.store.next_command()); self.assertEqual(self.store.job(identity)['state'],'expired')
        with patch.object(broker,'MAX_JOBS',1):
            with self.assertRaises(broker.BrokerError): self.job()
    def test_actual_https_pin_and_role_separation(self):
        server=broker.Server(('127.0.0.1',0),self.store)
        cfg=dict(self.store.config,baseURL=f'https://127.0.0.1:{server.server_address[1]}')
        broker.atomic_json(self.root/'config.json',cfg)
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        try:
            self.assertEqual(broker.request(self.root,'GET','/v2/status')['schema'],2)
            self.assertFalse(broker.request(self.root,'GET','/v2/status')['destructiveHardwareActions'])
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); context.check_hostname=False; context.verify_mode=ssl.CERT_NONE
            c=http.client.HTTPSConnection('127.0.0.1',server.server_address[1],context=context)
            c.request('GET','/v2/status',headers={'Authorization':'Bearer '+cfg['phoneToken']})
            response=c.getresponse(); self.assertEqual(response.status,404); response.read(); c.close()
            cfg['certificateSHA256']='f'*64; broker.atomic_json(self.root/'config.json',cfg)
            with self.assertRaisesRegex(broker.BrokerError,'tls_pin_mismatch'): broker.request(self.root,'GET','/v2/status')
        finally: server.shutdown(); server.server_close(); thread.join(2)

if __name__ == '__main__': unittest.main()
