import contextlib
import hashlib
import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'tools'), str(ROOT / 'tools/tests')]
import build_evidence as evidence
import incident_bundle as incident
import replay_scenario
from test_ride_diagnostics import event, bundle_manifest, required_sidecars, APP_STREAM_PATH, APP_CAPTURE_ID


class IncidentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        stream = (json.dumps(event()) + '\n').encode()
        manifest = bundle_manifest({APP_STREAM_PATH:stream})
        members = {'manifest.json':json.dumps(manifest).encode(), APP_STREAM_PATH:stream, **required_sidecars(manifest)}
        self.bundle = self.root / 'bundle.zip'
        with zipfile.ZipFile(self.bundle,'w',compression=zipfile.ZIP_STORED) as archive:
            for name, payload in members.items(): archive.writestr(name,payload)
            archive.writestr('checksums.sha256',''.join(f'{hashlib.sha256(payload).hexdigest()}  {name}\n' for name,payload in members.items()))
        self.context = self.root / 'context.json'
        self.context.write_text(json.dumps({'schema':1,'description':'Reconnect after blocked queue',
            'boardProfile':'WAVESHARE_AMOLED_175','captureIds':[APP_CAPTURE_ID],
            'observedFailureAt':'2026-10-01T00:00:00Z'}))
        self.scenario = ROOT / 'protocol/scenarios/ble-backpressure-reconnect.json'
        self.store = self.root / 'incidents'

    def test_pin_preserves_original_and_validates_scope_hashes_and_scenario(self):
        record = incident.create(self.bundle,self.context,self.scenario,[],self.store)
        self.assertEqual(evidence.sha(record/'bundle.zip'), evidence.sha(self.bundle))
        index = incident.verify(record)
        self.assertEqual(index['identity']['scenarioIdentity'],'ble-backpressure-reconnect-v1')
        self.assertEqual(index['identity']['replayStatus'],'not-run')
        self.assertEqual(index['identity']['appSymbols']['exactNativeCrashMatch'],[])
        (record/'bundle.zip').write_bytes(b'corruption')
        with self.assertRaisesRegex(ValueError,'hash mismatch'): incident.verify(record)

    def test_unrelated_capture_cannot_fill_incident(self):
        context = json.loads(self.context.read_text()); context['captureIds']=['00000000-0000-0000-0000-000000000002']
        self.context.write_text(json.dumps(context))
        with self.assertRaisesRegex(ValueError,'exactly match'): incident.create(self.bundle,self.context,self.scenario,[],self.store)

    def test_version_build_is_only_candidate_and_native_uuid_is_required(self):
        uuid = '00000000-0000-0000-0000-000000000001'
        identity = {'version':'1.4','build':'14','bundleIdentifier':'app.bike','machOUUIDs':[[uuid,'arm64']]}
        symbols = [('record',{'kind':'ios','identity':identity})]
        manifest = {'appBuildIdentity':{'version':'1.4','build':'14'}}
        self.assertEqual(incident.app_match(manifest,symbols)['exactNativeCrashMatch'],[])
        crash = {'bundleInfo':{'CFBundleIdentifier':'app.bike','CFBundleShortVersionString':'1.4','CFBundleVersion':'14'},
                 'usedImages':[{'name':'BikeComputer','uuid':uuid}]}
        self.assertEqual(incident.app_match(manifest,symbols,crash)['exactNativeCrashMatch'],['record'])
        crash['usedImages'][0]['uuid'] = '00000000-0000-0000-0000-000000000002'
        self.assertEqual(incident.app_match(manifest,symbols,crash)['exactNativeCrashMatch'],[])

    def test_native_crash_two_json_objects_are_supported(self):
        path = self.root / 'crash.ips'; path.write_text('{"app_name":"BikeComputer"}\n{"usedImages":[]}')
        self.assertEqual(incident.crash_data(path),{'usedImages':[]})

    def test_replay_retains_commit_and_latency_in_separate_immutable_receipt(self):
        record = incident.create(self.bundle,self.context,self.scenario,[],self.store)
        before = evidence.sha(record/'index.json')
        with patch.object(replay_scenario,'replay') as replay, patch.object(evidence,'source',return_value={'commit':'a'*40,'dirty':False}):
            receipt = incident.replay(record,self.root/'replays')
        replay.assert_called_once_with([record/'scenario.json'])
        self.assertEqual(evidence.sha(record/'index.json'),before)
        result = evidence.verify(receipt)['identity']
        self.assertEqual(result['source']['commit'],'a'*40)
        self.assertGreater(result['reportedFailureToReplaySeconds'],0)
        self.assertEqual(result['status'],'passed')


class ScenarioTests(unittest.TestCase):
    def test_versioned_library_validates(self):
        paths = list((ROOT/'protocol/scenarios').glob('*.json')); self.assertGreaterEqual(len(paths),2)
        for path in paths: self.assertEqual(replay_scenario.validate(path)['schema'],1)

    def test_unknown_or_empty_assertions_fail_validation(self):
        original = json.loads((ROOT/'protocol/scenarios/workout-delivery.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/'scenario.json'
            for step in ({'action':'expect'},{'action':'invented'}):
                path.write_text(json.dumps({**original,'steps':[step]}))
                with self.assertRaises(ValueError): replay_scenario.validate(path)


if __name__ == '__main__': unittest.main()
