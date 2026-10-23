import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(SCRIPTS))
import ci_scopes as scope
import changed_components as components
from dispatch_promotion_ci import eligible
from diagnostic_changes import changed


class ScopeTests(unittest.TestCase):
    def test_promotion_and_mixed_diff(self):
        locks=list(scope.COMPOSE_LOCKS)
        self.assertEqual(scope.map_scopes(locks,selected=True),dict.fromkeys(scope.MAP_SCOPES,False)|{'map_deploy':True})
        for paths in ([],None,locks+['map-platform/backend/map_platform/api.py'], ['map-platform/deploy/new-policy.py']):
            self.assertTrue(all(scope.map_scopes(paths,selected=True).values()))
        self.assertFalse(any(scope.map_scopes(locks,selected=False).values()))

    def test_catalog_does_not_pull_in_native_readers(self):
        self.assertEqual([k for k,v in scope.map_scopes(['map-platform/catalog/src/index.ts'],selected=True).items() if v],['map_catalog'])

    def test_firmware_profiles_and_boards(self):
        full=components.select_firmware_targets('175')
        targets=scope.firmware_targets(['esp32/lib/map_transfer/map_transfer.cpp'],full)
        self.assertEqual(targets,tuple(t for t in full if t.endswith(('_PRODUCTION','_LIFECYCLE_QUALIFICATION'))))
        self.assertIn('WAVESHARE_AMOLED_175_REMOTE_DEBUG',scope.firmware_targets(['esp32/lib/device_debug/device_debug_http.cpp'],full))
        for path in ('esp32/platformio.ini','esp32/tools/build_firmware.py','esp32/include/board.h','esp32/lib/panel/WAVESHARE_AMOLED_175.cpp'):
            self.assertEqual(len(scope.firmware_targets([path],full)),8,path)
        for path in ('esp32/waveshare_206_hello.cpp','esp32/lib/panel/WAVESHARE_AMOLED_206.cpp'):
            self.assertTrue(all('206' in t for t in scope.firmware_targets([path],full)))
        self.assertEqual(scope.firmware_targets(None,full),full)

    def test_ios_scopes_keep_consumers_and_unknown_fallback(self):
        select=lambda paths:scope.ios_scopes(paths,native=True,selected=True)
        radio=select(['ios-app/BikeComputerTests/WorldRadioTests.swift'])
        self.assertIn('ios-navigation-radio',radio['ios_checks'])
        self.assertNotIn('ios-navigation-map',radio['ios_checks'])
        self.assertFalse(radio['ios_simulator']);self.assertFalse(radio['ios_release'])
        shared=select(['ios-app/BikeComputer/WorkoutShared/WorkoutContract.swift'])
        self.assertTrue(shared['ios_simulator']);self.assertIn('ios-navigation-workout',shared['ios_checks'])
        self.assertIn('ios-navigation-map',shared['ios_checks'])
        for paths in (None,[],['tools/development/swift-sources.json'],['ios-app/BikeComputer/BikeComputer.xcodeproj/project.pbxproj']):
            self.assertTrue(select(paths)['ios_release']);self.assertTrue(select(paths)['ios_simulator'])
        unknown=select(['ios-app/BikeComputer/Unknown.swift'])
        self.assertTrue(all('ios-navigation-'+g in unknown['ios_checks'] for g in ('map','sensors','workout','radio')))
        # Deleted/renamed inputs select both consumers, even when the source no longer exists.
        mixed=select(['ios-app/BikeComputerTests/WorldRadioTests.swift','ios-app/BikeComputerTests/CyclingSensorTests.swift'])
        self.assertIn('ios-navigation-radio',mixed['ios_checks']);self.assertIn('ios-navigation-sensors',mixed['ios_checks'])

    def test_promotion_run_reuse_is_head_and_event_bound(self):
        run={'head_sha':'a'*40,'event':'pull_request','status':'completed','conclusion':'success'}
        self.assertTrue(eligible(run,'a'*40));self.assertFalse(eligible(run,'b'*40))
        for result in ('failure','cancelled','action_required','skipped'):
            self.assertFalse(eligible(run|{'conclusion':result},'a'*40))
        self.assertFalse(eligible(run|{'event':'push'},'a'*40))

    def test_diagnostics_comparison_fails_open_to_validation(self):
        self.assertTrue(changed(''))
        with patch('diagnostic_changes.subprocess.run') as run:
            for status in (0,1,128):
                run.return_value.returncode=status
                self.assertEqual(changed('a'*40),status!=0)

    def test_release_configuration_rejects_typos(self):
        sys.path.insert(0,str(scope.ROOT/'tools/development'))
        from ios_build import configurations
        self.assertEqual(configurations('Debug,Release'),('Debug','Release'))
        for value in ('','release','Debug,Debug','Debug,'):
            with self.assertRaises(ValueError):configurations(value)

if __name__=='__main__': unittest.main()
