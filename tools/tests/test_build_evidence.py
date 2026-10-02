import contextlib
import importlib.util
import io
import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import build_evidence as evidence


class BuildEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_symbols_are_immutable_reusable_and_verified(self):
        elf = self.root / 'firmware.elf'; elf.write_bytes(b'exact image')
        record = evidence.publish('firmware', {'binSha': 'a'*64}, {'firmware.elf': elf}, self.root / 'store')
        self.assertEqual(evidence.verify(record)['artifacts'][0]['sha256'], evidence.sha(elf))
        self.assertEqual(evidence.publish('firmware', {'binSha': 'a'*64}, {'firmware.elf': elf}, self.root / 'store'), record)
        (record / 'firmware.elf').write_bytes(b'corrupted')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'): evidence.verify(record)

    def test_symbol_path_symlink_is_rejected(self):
        file = self.root / 'elf'; file.write_bytes(b'image')
        record = evidence.publish('firmware', {}, {'nested/elf': file}, self.root / 'store')
        (record / 'nested/elf').unlink(); (record / 'nested/elf').symlink_to(file)
        with self.assertRaises(ValueError): evidence.verify(record)

    def test_unknown_miss_does_not_invent_an_input_change(self):
        manifest = {'environment':'WAVESHARE_AMOLED_175','coreCache':'miss','coreInputKey':'a', 'phaseTimingsMs':{'total':120}}
        first = evidence.cache_observation(manifest)
        warm = evidence.cache_observation(manifest, first)
        self.assertEqual(warm['changedInputs'], [])
        self.assertIn('absence, eviction or rejection', warm['explanation'])
        changed = evidence.cache_observation({**manifest, 'coreInputKey':'b'}, first)
        self.assertEqual(changed['changedInputs'], ['coreInputKey'])
        self.assertEqual(changed['previousPhaseTimingsMs'], {'total':120})

    def test_firmware_requires_matching_actual_image_and_map(self):
        project = self.root / 'esp32'; env = 'WAVESHARE_AMOLED_175'
        build = project / '.pio/build' / env; build.mkdir(parents=True)
        (build / 'firmware.elf').write_bytes(b'ELF'); (build / 'firmware.bin').write_bytes(b'BIN')
        (build / 'firmware.map').write_text('final map')
        manifest_path = project / '.pio/open-bike-build/builds' / env / 'current.json'; manifest_path.parent.mkdir(parents=True)
        manifest = {'environment':env,'uploadEligible':True, 'firmwareElfSha256':evidence.sha(build/'firmware.elf'),
            'firmwareBinSha256':evidence.sha(build/'firmware.bin'), 'coreCache':'miss','sourceIdentity':'a'*40}
        manifest_path.write_text(json.dumps(manifest))
        with contextlib.redirect_stdout(io.StringIO()): record = evidence.firmware(project, env, self.root / 'records')
        self.assertEqual(evidence.verify(record)['identity']['firmwareBinSha256'], manifest['firmwareBinSha256'])
        (build / 'firmware.bin').write_bytes(b'wrong')
        with self.assertRaisesRegex(ValueError, 'does not match'): evidence.firmware(project, env, self.root / 'records')

    def make_app(self):
        derived = self.root / 'Derived'; products = derived / 'Build/Products/Debug-iphoneos'
        app = products / 'BikeComputer.app'; app.mkdir(parents=True)
        (app / 'BikeComputer').write_bytes(b'MachO')
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'BikeComputer','CFBundleIdentifier':'app.bike',
            'CFBundleShortVersionString':'1','CFBundleVersion':'2'}))
        dsym = products / 'BikeComputer.app.dSYM/Contents/Resources/DWARF'; dsym.mkdir(parents=True)
        (dsym / 'BikeComputer').write_bytes(b'DWARF')
        return derived

    def test_app_symbols_require_matching_uuid_and_clean_unchanged_source(self):
        derived = self.make_app(); source = {'commit':'a'*40,'tree':'b'*40,'dirty':False}
        uuid = [('00000000-0000-0000-0000-000000000001','arm64')]
        with patch.object(evidence, 'source', return_value=source), patch.object(evidence, 'dwarf_uuids', return_value=uuid), contextlib.redirect_stdout(io.StringIO()):
            record = evidence.ios(derived, 'Debug', source, self.root / 'records')
        self.assertEqual(evidence.verify(record)['identity']['machOUUIDs'], [list(pair) for pair in uuid])
        with patch.object(evidence, 'source', return_value=source), patch.object(evidence, 'dwarf_uuids', side_effect=[uuid,[('different','arm64')]]):
            with self.assertRaisesRegex(ValueError, 'matching'): evidence.ios(derived, 'Debug', source, self.root / 'records')
        with patch.object(evidence, 'source', return_value={**source,'dirty':True}):
            with self.assertRaisesRegex(ValueError, 'clean'): evidence.ios(derived, 'Debug', source, self.root / 'records')


if __name__ == '__main__': unittest.main()
