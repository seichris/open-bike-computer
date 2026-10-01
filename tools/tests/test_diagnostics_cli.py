import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from bicino_diagnostics import cli
from bicino_diagnostics.bundle import open_evidence, EvidenceError
from diagnostics_test_support import v1_fixture,v2_fixture,write_zip


class DiagnosticsCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory()
        self.root=Path(self.temporary.name)
        self.inner=self.root/'inner.zip'
        self.chunk=v1_fixture(self.inner)
        self.bundle=self.root/'bundle.zip'
        self.acquisition=v2_fixture(self.bundle,self.inner,self.chunk)
    def tearDown(self): self.temporary.cleanup()
    def invoke(self,*args):
        output=io.StringIO()
        with contextlib.redirect_stdout(output): status=cli.main(['diag',*map(str,args),'--json'])
        return status,json.loads(output.getvalue())
    def test_verify_complete_checks_actual_bytes(self):
        status,result=self.invoke('verify',self.bundle,'--require-complete')
        self.assertEqual(status,0,result)
        self.assertEqual(result['delivery'][0]['state'],'complete')
        self.assertEqual(result['recordingCoverage'],'no_detected_loss')
        self.assertEqual(result['sources'],['firmware','ios'])
    def test_unknown_scope_cannot_borrow_another_rides_evidence(self):
        unknown='00000000-0000-0000-0000-000000000123'
        for selector in ('--capture', '--acquisition'):
            status,result=self.invoke('verify',self.bundle,selector,unknown,'--require-complete')
            self.assertEqual(status,3,result)
            self.assertEqual(result['eventCount'],0)
            self.assertEqual(result['missingRequiredSources'],['firmware','ios'])
            self.assertEqual(result['scope']['matchedAcquisitions'],0)
        status,result=self.invoke('verify',self.bundle,'--device','0000000000000000','--require-complete')
        self.assertEqual(status,3,result)
        self.assertEqual(result['missingRequiredSources'],['firmware'])

    def test_acquisition_derives_original_capture_and_device(self):
        status,result=self.invoke('verify',self.bundle,'--acquisition',self.acquisition['id'],'--require-complete')
        self.assertEqual(status,0,result)
        self.assertEqual(result['scope']['capture'],self.acquisition['captureID'].lower())
        self.assertEqual(result['scope']['device'],self.acquisition['deviceDigest'])
        status,result=self.invoke('verify',self.bundle,'--acquisition',self.acquisition['id'],
            '--device','0000000000000000','--require-complete')
        self.assertEqual(status,3,result)
        self.assertEqual(result['eventCount'],0)

    def test_unrelated_historical_partial_job_does_not_poison_scoped_delivery(self):
        with zipfile.ZipFile(self.bundle) as archive:
            members={name:archive.read(name) for name in archive.namelist() if name!='checksums.sha256'}
        old=dict(self.acquisition,id='00000000-0000-0000-0000-000000000222',
                 captureID='00000000-0000-0000-0000-000000000333',phase='partial',expected=[],verified=[])
        old.pop('indexData')
        name='acquisitions/'+old['id']+'.json'
        members[name]=json.dumps(old).encode()
        envelope=json.loads(members['manifest.json']);envelope['acquisitions'].append(name)
        members['manifest.json']=json.dumps(envelope).encode()
        write_zip(self.bundle,members)
        self.assertEqual(self.invoke('verify',self.bundle,'--require-complete')[0],3)
        status,result=self.invoke('verify',self.bundle,'--capture',self.acquisition['captureID'],'--require-complete')
        self.assertEqual(status,0,result)
        self.assertEqual(len(result['delivery']),1)

    def test_analyzer_coverage_and_queries_use_the_same_canonical_scope(self):
        status,result=self.invoke('analyze',self.bundle,'--capture','00000000-0000-0000-0000-000000000111')
        self.assertEqual(status,0,result)
        self.assertEqual(result['matchedEvents'],0)
        self.assertEqual(result['coverage']['eventCount'],0)
        status,result=self.invoke('query',self.bundle,'--capture',self.acquisition['captureID'].replace('-','').upper())
        self.assertEqual(status,0,result)
        self.assertEqual(result['matchedEvents'],4)

    def test_unknown_acquisition_origin_is_not_accepted(self):
        from bicino_diagnostics.bundle import validate_acquisition
        self.assertEqual(validate_acquisition(dict(self.acquisition, origin='post_ride'))['origin'], 'post_ride')
        with self.assertRaisesRegex(EvidenceError, 'origin'):
            validate_acquisition(dict(self.acquisition, origin='remote_arbitrary'))

    def test_false_receipt_does_not_make_missing_evidence_complete(self):
        v1_fixture(self.inner,include_device=False)
        v2_fixture(self.bundle,self.inner,self.chunk,claims_complete=True)
        status,result=self.invoke('verify',self.bundle,'--require-complete')
        self.assertEqual(status,3,result)
        self.assertEqual(result['delivery'][0]['state'],'incomplete')
        self.assertEqual(result['missingRequiredSources'],['firmware'])
    def test_legacy_evidence_integrity_is_not_delivery_completeness(self):
        status,result=self.invoke('verify',self.inner,'--require-complete')
        self.assertEqual(status,3)
        self.assertEqual(result['integrity'],'verified')
        self.assertEqual(result['deliveryEvidence'],'no_acquisition_manifest')
    def test_query_pages_keep_raw_references_and_bind_cursor(self):
        status,first=self.invoke('query',self.bundle,'--source','ios','--limit','1')
        self.assertEqual(status,0,first)
        self.assertEqual(first['events'][0]['rawReference']['line'],1)
        status,second=self.invoke('query',self.bundle,'--source','ios','--limit','1','--cursor',first['nextCursor'])
        self.assertEqual(status,0,second)
        self.assertEqual(second['events'][0]['sequence'],1)
        status,result=self.invoke('query',self.bundle,'--source','firmware','--cursor',first['nextCursor'])
        self.assertEqual(status,2)
        self.assertIn('cursor',result['message'])
    def test_import_preserves_bytes_and_refuses_clobber(self):
        out=self.root/'copy.zip'
        status,result=self.invoke('import',self.bundle,'--output',out)
        self.assertEqual(status,0,result)
        self.assertEqual(out.read_bytes(),self.bundle.read_bytes())
        self.assertEqual(out.stat().st_mode & 0o777,0o600)
        status,_=self.invoke('import',self.bundle,'--output',out)
        self.assertEqual(status,2)
    def test_tampered_hash_and_extra_member_rejected(self):
        with zipfile.ZipFile(self.bundle) as archive: members={name:archive.read(name) for name in archive.namelist() if name!='checksums.sha256'}
        members['secret.txt']=b'should-not-enter-evidence'
        write_zip(self.bundle,members)
        self.assertEqual(self.invoke('verify',self.bundle)[0],2)
        v2_fixture(self.bundle,self.inner,self.chunk)
        with self.bundle.open('r+b') as output:
            output.seek(200);original=output.read(1);output.seek(200);output.write(bytes([original[0]^1]))
        self.assertEqual(self.invoke('verify',self.bundle)[0],2)
    def test_doctor_is_nonmutating_and_registry_matches_generated(self):
        missing=self.root/'uninitialized'
        status,result=self.invoke('--broker-root',missing,'doctor')
        self.assertEqual(status,0,result)
        self.assertFalse(missing.exists())
        self.assertFalse(result['hardwareProbed'])
        generated=(ROOT/'esp32/lib/ride_diagnostics/diagnostics_registry_identity.hpp').read_text()
        self.assertIn(result['registryDigest'],generated)
    def test_unknown_device_requires_observation(self):
        status,result=self.invoke('--broker-root',self.root/'missing','capture','start',
            '--device','0123456789abcdef','--domains','ble','--duration','2h')
        self.assertEqual(status,2,result)
        self.assertFalse((self.root/'missing').exists())
    def test_command_entrypoint_works_from_another_directory(self):
        result=subprocess.run([sys.executable,str(ROOT/'tools/bicino'),'diag','capabilities','--offline','--json'],
            cwd=self.root,text=True,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr+result.stdout)
        self.assertEqual(json.loads(result.stdout)['scope'],'checked_in_contract_not_device_observation')
    def test_summary_has_refs_not_a_causal_assertion(self):
        status,result=self.invoke('analyze',self.bundle)
        self.assertEqual(status,0,result)
        self.assertIn('not a causal diagnosis',result['interpretation'])

if __name__=='__main__': unittest.main()
